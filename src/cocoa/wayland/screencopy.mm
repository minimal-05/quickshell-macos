// Compiled with -fobjc-arc (see CMakeLists.txt): SCK hands out objects through
// completion blocks on its own queues, and manual retain/release across those
// hops is exactly the kind of thing that leaks a stream per overview open.
#include "screencopy.hpp"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include <functional>
#include <memory>
#include <mutex>
#include <utility>
#include <vector>

#include <qcoreapplication.h>
#include <qlogging.h>
#include <qnamespace.h>
#include <qpointer.h>
#include <qqmlinfo.h>
#include <qquickwindow.h>
#include <qscreen.h>
#include <qsgsimpletexturenode.h>
#include <qsgtexture.h>

#include "../../core/qmlscreen.hpp"

namespace qs::cocoa {

namespace {

// SCK calls back on its own queues; QQuickItem state belongs to the GUI
// thread. Every callback hops through here and re-checks its QPointer.
void onGuiThread(std::function<void()> fn) {
	QMetaObject::invokeMethod(QCoreApplication::instance(), std::move(fn), Qt::QueuedConnection);
}

// One SCShareableContent fetch serves every view that asks within a second.
// Each fetch is an XPC round trip to the capture server that enumerates every
// window on the system, and the overview creates a view per window at once.
struct ShareableContent {
	using Callback = std::function<void(SCShareableContent*, NSError*)>;

	static void get(Callback callback) {
		auto& self = instance();

		if (self.content != nil && CFAbsoluteTimeGetCurrent() - self.fetchedAt < 1.0) {
			callback(self.content, nil);
			return;
		}

		self.waiters.push_back(std::move(callback));
		if (self.inflight) return;
		self.inflight = true;

		[SCShareableContent getShareableContentExcludingDesktopWindows:YES
		                                            onScreenWindowsOnly:NO
		                                              completionHandler:^(SCShareableContent* content, NSError* error) {
			                                              onGuiThread([content, error] {
				                                              auto& self = instance();
				                                              self.inflight = false;
				                                              if (content != nil) {
					                                              self.content = content;
					                                              self.fetchedAt = CFAbsoluteTimeGetCurrent();
				                                              }
				                                              auto waiters = std::move(self.waiters);
				                                              self.waiters.clear();
				                                              for (auto& waiter: waiters) waiter(content, error);
			                                              });
		                                              }];
	}

private:
	static ShareableContent& instance() {
		static ShareableContent content;
		return content;
	}

	SCShareableContent* content = nil;
	CFAbsoluteTime fetchedAt = 0;
	bool inflight = false;
	std::vector<Callback> waiters;
};

// Latest frame from the stream queue, one GUI-thread notification at a time.
// Frames that arrive while a notification is pending replace the pending
// image rather than queueing behind it, so a stalled GUI thread never has a
// backlog of stale frames to chew through.
struct FrameSink {
	std::mutex mutex;
	QImage latest;
	bool posted = false;
};

// Qt's cocoa QScreen geometry is CGDisplayBounds verbatim, so the display is
// the one whose bounds match; the point test covers a mirrored or moved
// display that changed size since Qt last looked.
CGDirectDisplayID displayIdFor(QScreen* screen) {
	if (screen == nullptr) return kCGNullDirectDisplay;
	auto geometry = screen->geometry();

	uint32_t count = 0;
	CGDirectDisplayID ids[16]; // NOLINT
	if (CGGetActiveDisplayList(16, ids, &count) != kCGErrorSuccess) return kCGNullDirectDisplay;

	for (uint32_t i = 0; i < count; ++i) {
		auto bounds = CGDisplayBounds(ids[i]);
		if (QRectF::fromCGRect(bounds).toRect() == geometry) return ids[i];
	}

	auto center = geometry.center();
	uint32_t found = 0;
	CGDirectDisplayID hit = kCGNullDirectDisplay;
	if (CGGetDisplaysWithPoint(CGPointMake(center.x(), center.y()), 1, &hit, &found) == kCGErrorSuccess
	    && found == 1)
	{
		return hit;
	}

	return kCGNullDirectDisplay;
}

API_AVAILABLE(macos(14.0))
SCContentFilter* filterFor(QObject* source, SCShareableContent* content, QString& reason) {
	if (auto* screen = qobject_cast<QuickshellScreenInfo*>(source)) {
		auto id = displayIdFor(screen->screen);
		for (SCDisplay* display in content.displays) {
			if (display.displayID == id) {
				return [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
			}
		}
		reason = QStringLiteral("screen is not shareable");
		return nil;
	}

	// The Toplevel shim's `wid` is yabai's window id, which is the CGWindowID.
	auto wid = source->property("wid");
	if (wid.isValid() && wid.canConvert<int>()) {
		auto id = static_cast<CGWindowID>(wid.toInt());
		for (SCWindow* window in content.windows) {
			if (window.windowID == id) {
				return [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
			}
		}
		reason = QStringLiteral("window %1 is not shareable").arg(wid.toInt());
		return nil;
	}

	reason = QStringLiteral("capture source is not a ShellScreen or Toplevel");
	return nil;
}

// Output pixels: the constraint (or the item's own box) at the window's scale,
// never larger than the source. Upstream receives buffers at source size and
// lets the scene graph scale; asking SCK for the display size instead keeps a
// 200 px thumbnail of a 4K window from streaming 4K.
QSize outputSizeFor(QSize source, QSizeF constraint, QSizeF item, qreal dpr) {
	auto size = source.toSizeF();
	auto box = constraint;
	if (box.width() <= 0 && box.height() <= 0) box = item;

	if (box.width() > 0 && box.height() > 0) {
		size.scale(box.width() * dpr, box.height() * dpr, Qt::KeepAspectRatio);
	} else if (box.width() > 0) {
		size *= (box.width() * dpr) / size.width();
	} else if (box.height() > 0) {
		size *= (box.height() * dpr) / size.height();
	}

	if (size.width() > source.width() || size.height() > source.height()) size = source.toSizeF();
	return QSize(qMax(1, qRound(size.width())), qMax(1, qRound(size.height())));
}

API_AVAILABLE(macos(14.0))
SCStreamConfiguration* configurationFor(QSize output, bool cursor) {
	auto* config = [[SCStreamConfiguration alloc] init];
	config.width = static_cast<size_t>(output.width());
	config.height = static_cast<size_t>(output.height());
	config.pixelFormat = kCVPixelFormatType_32BGRA;
	config.showsCursor = cursor;
	config.scalesToFit = YES;
	config.preservesAspectRatio = YES;
	config.captureResolution = SCCaptureResolutionBest;
	// The shadow is outside the window frame; leaving it in would shrink the
	// content inside the output and put the frame out of step with yabai's.
	config.ignoreShadowsSingleWindow = YES;
	// ponytail: 30 fps is plenty for previews and half the wakeups of the
	// display rate. Ceiling: a preview never shows more than 30 fps. Upgrade
	// path: expose it, or derive it from the item's window refresh rate.
	config.minimumFrameInterval = CMTimeMake(1, 30);
	return config;
}

QImage imageFromCGImage(CGImageRef image) {
	auto width = static_cast<int>(CGImageGetWidth(image));
	auto height = static_cast<int>(CGImageGetHeight(image));
	if (width <= 0 || height <= 0) return {};

	QImage out(width, height, QImage::Format_ARGB32_Premultiplied);
	out.fill(Qt::transparent);

	auto* colorSpace = CGColorSpaceCreateDeviceRGB();
	auto* context = CGBitmapContextCreate(
	    out.bits(),
	    static_cast<size_t>(width),
	    static_cast<size_t>(height),
	    8,
	    static_cast<size_t>(out.bytesPerLine()),
	    colorSpace,
	    static_cast<uint32_t>(kCGImageAlphaPremultipliedFirst) | static_cast<uint32_t>(kCGBitmapByteOrder32Little)
	);

	if (context != nullptr) {
		CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
		CGContextRelease(context);
	} else {
		out = QImage();
	}

	CGColorSpaceRelease(colorSpace);
	return out;
}

// ponytail: a CPU copy out of the IOSurface, then a texture upload in
// updatePaintNode. Ceiling: a few hundred KB per frame at thumbnail sizes,
// which is what outputSizeFor keeps us at. Upgrade path: wrap the IOSurface in
// an MTLTexture and hand it to QNativeInterface::QSGMetalTexture::fromNative,
// zero copies.
QImage imageFromPixelBuffer(CVPixelBufferRef pixels) {
	if (CVPixelBufferGetPixelFormatType(pixels) != kCVPixelFormatType_32BGRA) return {};
	if (CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return {};

	QImage out;
	auto* base = static_cast<const uchar*>(CVPixelBufferGetBaseAddress(pixels));
	auto width = static_cast<int>(CVPixelBufferGetWidth(pixels));
	auto height = static_cast<int>(CVPixelBufferGetHeight(pixels));
	auto stride = static_cast<qsizetype>(CVPixelBufferGetBytesPerRow(pixels));

	if (base != nullptr && width > 0 && height > 0) {
		out = QImage(base, width, height, stride, QImage::Format_ARGB32_Premultiplied).copy();
	}

	CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
	return out;
}

bool isPermissionError(NSError* error) {
	return error != nil && [error.domain isEqualToString:SCStreamErrorDomain]
	    && error.code == SCStreamErrorUserDeclined;
}

void logPermissionOnce() {
	static bool logged = false;
	if (logged) return;
	logged = true;
	auto* bundle = NSBundle.mainBundle.bundleIdentifier;
	qWarning() << "ScreencopyView: Screen Recording is not granted to"
	           << (bundle != nil ? bundle.UTF8String : "this unbundled binary")
	           << "- captures disabled. Grant it under System Settings > Privacy & Security >"
	              " Screen Recording and restart.";
}

} // namespace

} // namespace qs::cocoa

// Stream output and delegate. Frames arrive on the stream's private queue;
// stops can arrive on any queue. Both cross to the GUI thread carrying the
// generation they belong to, so a stream torn down while a frame was in
// flight cannot paint into its successor.
@interface QSScreencopyOutput: NSObject <SCStreamOutput, SCStreamDelegate>
- (instancetype)initWithView:(qs::cocoa::ScreencopyView*)view generation:(quint64)generation;
@end

@implementation QSScreencopyOutput {
	QPointer<qs::cocoa::ScreencopyView> _view;
	std::shared_ptr<qs::cocoa::FrameSink> _sink;
	quint64 _generation;
}

- (instancetype)initWithView:(qs::cocoa::ScreencopyView*)view generation:(quint64)generation {
	if ((self = [super init])) {
		_view = view;
		_sink = std::make_shared<qs::cocoa::FrameSink>();
		_generation = generation;
	}
	return self;
}

- (void)stream:(SCStream*)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
	(void) stream;
	if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sampleBuffer)) return;

	// Idle frames repeat the previous image, blank/suspended ones have none.
	auto* attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
	if (attachments != nullptr && CFArrayGetCount(attachments) > 0) {
		auto* info = (__bridge NSDictionary*) CFArrayGetValueAtIndex(attachments, 0);
		NSNumber* status = info[SCStreamFrameInfoStatus];
		if (status != nil && status.integerValue != SCFrameStatusComplete
		    && status.integerValue != SCFrameStatusStarted)
		{
			return;
		}
	}

	auto* pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
	if (pixels == nullptr) return;
	auto image = qs::cocoa::imageFromPixelBuffer(pixels);
	if (image.isNull()) return;

	{
		std::lock_guard<std::mutex> lock(_sink->mutex);
		_sink->latest = image;
		if (_sink->posted) return;
		_sink->posted = true;
	}

	auto view = _view;
	auto sink = _sink;
	auto generation = _generation;
	qs::cocoa::onGuiThread([view, sink, generation] {
		QImage frame;
		{
			std::lock_guard<std::mutex> lock(sink->mutex);
			frame = std::move(sink->latest);
			sink->latest = QImage();
			sink->posted = false;
		}
		if (auto* v = view.data()) v->deliverFrame(frame, generation);
	});
}

- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
	(void) stream;
	auto view = _view;
	auto generation = _generation;
	auto reason = QString::fromNSString(error.localizedDescription);
	auto code = static_cast<qint64>(error.code);
	auto permission = qs::cocoa::isPermissionError(error);
	qs::cocoa::onGuiThread([view, generation, reason, code, permission] {
		if (auto* v = view.data()) {
			if (permission) v->captureFailed(generation, code, reason);
			else v->streamEnded(generation, reason);
		}
	});
}

@end

namespace qs::cocoa {

struct ScreencopyView::Impl {
	SCStream* stream = nil;
	QSScreencopyOutput* output = nil;
	dispatch_queue_t queue = nil;
	// Bumped on every start and teardown. Callbacks carry the value they were
	// started with and are dropped when it no longer matches.
	quint64 generation = 0;
	bool paused = false;

	void teardown() {
		this->generation++;
		this->paused = false;

		if (this->stream != nil) {
			SCStream* stream = this->stream;
			// The block keeps the stream alive until SCK has actually stopped it.
			[stream stopCaptureWithCompletionHandler:^(NSError* error) {
				(void) error;
				(void) stream;
			}];
			this->stream = nil;
		}

		this->output = nil;
		this->queue = nil;
	}

	API_AVAILABLE(macos(14.0))
	void startStream(ScreencopyView* view, SCContentFilter* filter, SCStreamConfiguration* config) {
		auto generation = this->generation;
		this->queue = dispatch_queue_create("org.quickshell.screencopy", DISPATCH_QUEUE_SERIAL);
		this->output = [[QSScreencopyOutput alloc] initWithView:view generation:generation];
		this->stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:this->output];

		NSError* error = nil;
		if (![this->stream addStreamOutput:this->output
		                              type:SCStreamOutputTypeScreen
		                sampleHandlerQueue:this->queue
		                             error:&error])
		{
			view->captureFailed(
			    generation,
			    error.code,
			    QString::fromNSString(error.localizedDescription)
			);
			return;
		}

		QPointer<ScreencopyView> weak(view);
		[this->stream startCaptureWithCompletionHandler:^(NSError* error) {
			if (error == nil) return;
			auto code = static_cast<qint64>(error.code);
			auto description = QString::fromNSString(error.localizedDescription);
			onGuiThread([weak, generation, code, description] {
				if (auto* v = weak.data()) v->captureFailed(generation, code, description);
			});
		}];
	}

	API_AVAILABLE(macos(14.0))
	static void captureStill(ScreencopyView* view, SCContentFilter* filter, SCStreamConfiguration* config, quint64 generation) {
		QPointer<ScreencopyView> weak(view);
		[SCScreenshotManager captureImageWithFilter:filter
		                              configuration:config
		                          completionHandler:^(CGImageRef image, NSError* error) {
			                          // The CGImage is only valid inside the handler.
			                          auto frame = image != nullptr ? imageFromCGImage(image) : QImage();
			                          auto code = static_cast<qint64>(error != nil ? error.code : 0);
			                          auto description =
			                              error != nil ? QString::fromNSString(error.localizedDescription) : QString();
			                          onGuiThread([weak, generation, frame, code, description] {
				                          auto* v = weak.data();
				                          if (v == nullptr) return;
				                          if (frame.isNull()) v->captureFailed(generation, code, description);
				                          else v->deliverFrame(frame, generation);
			                          });
		                          }];
	}
};

ScreencopyView::ScreencopyView(QQuickItem* parent): QQuickItem(parent), impl(new Impl()) {
	this->setFlag(QQuickItem::ItemHasContents);
}

ScreencopyView::~ScreencopyView() {
	this->impl->teardown();
	delete this->impl;
}

void ScreencopyView::componentComplete() {
	this->QQuickItem::componentComplete();
	this->completed = true;
	this->restart();
}

void ScreencopyView::setCaptureSource(QObject* captureSource) {
	if (captureSource == this->mCaptureSource) return;

	if (this->mCaptureSource != nullptr) {
		QObject::disconnect(this->mCaptureSource, nullptr, this, nullptr);
	}

	this->mCaptureSource = captureSource;

	if (captureSource != nullptr) {
		QObject::connect(captureSource, &QObject::destroyed, this, &ScreencopyView::onSourceDestroyed);
	}

	this->clearFrames();
	this->restart();
	emit this->captureSourceChanged();
}

void ScreencopyView::onSourceDestroyed() {
	this->mCaptureSource = nullptr;
	this->clearFrames();
	this->restart();
	emit this->captureSourceChanged();
}

void ScreencopyView::setPaintCursor(bool paintCursor) {
	if (paintCursor == this->mPaintCursor) return;
	this->mPaintCursor = paintCursor;
	this->restart();
	emit this->paintCursorChanged();
}

void ScreencopyView::setLive(bool live) {
	if (live == this->mLive) return;
	this->mLive = live;
	this->restart();
	emit this->liveChanged();
}

void ScreencopyView::setConstraintSize(QSizeF constraintSize) {
	if (constraintSize == this->mConstraintSize) return;
	this->mConstraintSize = constraintSize;
	this->updateImplicitSize();
	// ponytail: the output size is fixed at stream start, so a new constraint
	// restarts the stream. Ceiling: a constraint animated every frame would
	// thrash SCK. Upgrade path: SCStream updateConfiguration:.
	if (this->impl->stream != nil) this->restart();
	emit this->constraintSizeChanged();
}

void ScreencopyView::captureFrame() {
	if (this->mCaptureSource == nullptr) {
		qmlWarning(this) << "Cannot capture frame, no capture source is set.";
		return;
	}
	this->restart();
}

// Ends the stream and keeps it ended: a paused stream would otherwise come
// back with the window. The last frame stays up, as it does upstream.
void ScreencopyView::stop() {
	this->impl->teardown();
	if (this->mCaptureSource != nullptr) this->setStatus(QStringLiteral("stopped"));
}

bool ScreencopyView::canStream() const {
	return this->isVisible() && this->window() != nullptr && this->windowVisible;
}

void ScreencopyView::pause() {
	if (this->impl->stream == nil && this->mStatus != QStringLiteral("pending")) return;
	this->impl->teardown();
	this->impl->paused = true;
	this->setStatus(QStringLiteral("paused"));
}

void ScreencopyView::restart() {
	this->impl->teardown();
	if (!this->completed) return;

	if (this->mCaptureSource == nullptr) {
		this->setStatus(QStringLiteral("idle"));
		return;
	}

	// A stream nobody can see is pure cost; a still is cheap and consumers
	// take it before showing the window that displays it.
	if (this->mLive && !this->canStream()) {
		this->impl->paused = true;
		this->setStatus(QStringLiteral("paused"));
		return;
	}

	// Preflight never prompts. Asking SCK without the grant would pop the
	// system dialog from inside a bar or an overview tile, which is not this
	// item's decision to make. QS_SCREENCOPY_DENY walks this branch on a
	// machine that holds the grant (tests/screencopy.sh); TCC cannot be
	// revoked per process.
	if (!CGPreflightScreenCaptureAccess() || qEnvironmentVariableIsSet("QS_SCREENCOPY_DENY")) {
		logPermissionOnce();
		this->setStatus(QStringLiteral("permission"));
		return;
	}

	if (@available(macOS 14.0, *)) {
		this->setStatus(QStringLiteral("pending"));
		auto generation = this->impl->generation;
		QPointer<ScreencopyView> weak(this);

		ShareableContent::get([weak, generation](SCShareableContent* content, NSError* error) {
			auto* self = weak.data();
			if (self == nullptr || self->impl->generation != generation) return;

			if (content == nil) {
				self->captureFailed(
				    generation,
				    error != nil ? error.code : 0,
				    error != nil ? QString::fromNSString(error.localizedDescription) : QString()
				);
				return;
			}

			QString reason;
			SCContentFilter* filter = filterFor(self->mCaptureSource, content, reason);
			if (filter == nil) {
				qmlWarning(self) << "Capture source is not capturable:" << reason;
				self->setStatus(QStringLiteral("unavailable"));
				return;
			}

			auto scale = filter.pointPixelScale;
			auto rect = filter.contentRect;
			auto source = QSize(qRound(rect.size.width * scale), qRound(rect.size.height * scale));
			self->setSourceSize(source);

			auto dpr = self->window() != nullptr ? self->window()->effectiveDevicePixelRatio() : 1.0;
			auto output = outputSizeFor(source, self->mConstraintSize, self->size(), dpr);
			auto* config = configurationFor(output, self->mPaintCursor);

			if (self->mLive) self->impl->startStream(self, filter, config);
			else Impl::captureStill(self, filter, config, generation);
		});
	} else {
		// ponytail: SCScreenshotManager and SCContentFilter.contentRect are 14+.
		// Ceiling: macOS 13 gets no captures. Upgrade path: a one-frame SCStream
		// for stills and SCShareableContentInfo for the size.
		qmlWarning(this) << "ScreencopyView needs macOS 14 or newer.";
		this->setStatus(QStringLiteral("unavailable"));
	}
}

void ScreencopyView::deliverFrame(const QImage& frame, quint64 generation) {
	if (generation != this->impl->generation || frame.isNull()) return;

	this->frame = frame;
	this->frameDirty = true;
	this->mFrameCount++;
	emit this->frameCountChanged();

	if (this->mSourceSize.isEmpty()) this->setSourceSize(frame.size());
	this->setHasContent(true);
	this->setStatus(QStringLiteral("ok"));
	this->update();
}

void ScreencopyView::streamEnded(quint64 generation, const QString& reason) {
	if (generation != this->impl->generation) return;
	this->impl->teardown();
	if (!reason.isEmpty()) qmlWarning(this) << "Stream ended:" << reason;
	this->setStatus(QStringLiteral("stopped"));
	emit this->stopped();
}

void ScreencopyView::captureFailed(quint64 generation, qint64 code, const QString& description) {
	if (generation != this->impl->generation) return;
	this->impl->teardown();

	if (code == SCStreamErrorUserDeclined) {
		logPermissionOnce();
		this->setStatus(QStringLiteral("permission"));
		return;
	}

	qmlWarning(this) << "Capture failed (" << code << "):" << description;
	this->setStatus(QStringLiteral("error"));
}

void ScreencopyView::clearFrames() {
	this->frame = QImage();
	this->frameDirty = false;
	this->mFrameCount = 0;
	emit this->frameCountChanged();
	this->setHasContent(false);
	this->setSourceSize(QSize(0, 0));
	this->update();
}

void ScreencopyView::itemChange(ItemChange change, const ItemChangeData& value) {
	if (change == QQuickItem::ItemSceneChange) {
		// window() already points at the new scene here; the old one was kept.
		if (this->trackedWindow != nullptr) QObject::disconnect(this->trackedWindow, nullptr, this, nullptr);
		this->trackedWindow = value.window;
		if (value.window != nullptr) {
			QObject::connect(
			    value.window,
			    &QQuickWindow::visibleChanged,
			    this,
			    &ScreencopyView::onWindowVisibleChanged
			);
		}
		this->windowVisible = value.window != nullptr && value.window->isVisible();
	}

	this->QQuickItem::itemChange(change, value);

	if (change == QQuickItem::ItemVisibleHasChanged || change == QQuickItem::ItemSceneChange) {
		if (!this->mLive || !this->completed || this->mStatus == QStringLiteral("stopped")) return;
		if (!this->canStream()) this->pause();
		else if (this->impl->paused) this->restart();
	}
}

void ScreencopyView::onWindowVisibleChanged() {
	this->windowVisible = this->window() != nullptr && this->window()->isVisible();
	if (!this->mLive || !this->completed || this->mStatus == QStringLiteral("stopped")) return;
	if (!this->canStream()) this->pause();
	else if (this->impl->paused) this->restart();
}

QSGNode* ScreencopyView::updatePaintNode(QSGNode* oldNode, UpdatePaintNodeData* /*unused*/) {
	if (!this->mHasContent || this->frame.isNull() || this->window() == nullptr) {
		delete oldNode;
		return nullptr;
	}

	auto* node = static_cast<QSGSimpleTextureNode*>(oldNode); // NOLINT
	if (node == nullptr) {
		node = new QSGSimpleTextureNode();
		node->setOwnsTexture(true);
		node->setFiltering(QSGTexture::Linear);
		this->frameDirty = true;
	}

	if (this->frameDirty) {
		auto* texture =
		    this->window()->createTextureFromImage(this->frame, QQuickWindow::TextureHasAlphaChannel);
		if (texture == nullptr) {
			delete node;
			return nullptr;
		}
		node->setTexture(texture);
		this->frameDirty = false;
	}

	node->setRect(this->boundingRect());
	return node;
}

void ScreencopyView::setStatus(const QString& status) {
	if (status == this->mStatus) return;
	this->mStatus = status;
	emit this->statusChanged();
}

void ScreencopyView::setHasContent(bool hasContent) {
	if (hasContent == this->mHasContent) return;
	this->mHasContent = hasContent;
	emit this->hasContentChanged();
}

void ScreencopyView::setSourceSize(QSize size) {
	if (size == this->mSourceSize) return;
	this->mSourceSize = size;
	this->updateImplicitSize();
	emit this->sourceSizeChanged();
}

// Same rule as upstream: the constraint bounds the implicit size while the
// source aspect ratio is kept; with no constraint the source size is used.
void ScreencopyView::updateImplicitSize() {
	auto constraint = this->mConstraintSize;
	auto size = this->mSourceSize.toSizeF();

	if (constraint.width() > 0 && constraint.height() > 0) {
		size.scale(constraint.width(), constraint.height(), Qt::KeepAspectRatio);
	} else if (constraint.width() > 0 && size.width() > 0) {
		size = QSizeF(constraint.width(), size.height() * constraint.width() / size.width());
	} else if (constraint.height() > 0 && size.height() > 0) {
		size = QSizeF(size.width() * constraint.height() / size.height(), constraint.height());
	}

	this->setImplicitSize(qMax(0.0, size.width()), qMax(0.0, size.height()));
}

} // namespace qs::cocoa
