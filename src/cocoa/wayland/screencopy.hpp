#pragma once

#include <qimage.h>
#include <qobject.h>
#include <qpointer.h>
#include <qqmlintegration.h>
#include <qquickitem.h>
#include <qquickwindow.h>
#include <qsize.h>
#include <qstring.h>
#include <qtmetamacros.h>
#include <qtypes.h>

// A macOS stand-in for the wlr-screencopy / hyprland-toplevel-export view.
//
// Upstream streams frames from the compositor into a QSG texture. Here the
// frames come from ScreenCaptureKit, in-process: a still through
// SCScreenshotManager, a live feed through an SCStream whose output runs on a
// private queue and hands finished frames to the GUI thread. Nothing is
// spawned and nothing touches the disk.
//
// Capture sources, as upstream:
//   Quickshell.ShellScreen          -> SCDisplay (by CGDirectDisplayID)
//   Quickshell.Wayland.Toplevel     -> SCWindow  (by the shim's `wid`, which is
//                                      the CGWindowID yabai reports)
//
// Screen Recording is a TCC grant keyed on the bundle. When it is missing the
// view degrades instead of prompting: `status` becomes "permission",
// `hasContent` stays false, one warning is logged for the process.

namespace qs::cocoa {

///! Displays a still or live capture of a window or a screen.
class ScreencopyView: public QQuickItem {
	Q_OBJECT;
	QML_ELEMENT;
	// clang-format off
	/// A @@Quickshell.ShellScreen or a @@Quickshell.Wayland.Toplevel, or null to clear.
	Q_PROPERTY(QObject* captureSource READ captureSource WRITE setCaptureSource NOTIFY captureSourceChanged);
	/// Paint the system cursor into the capture. Defaults to false.
	Q_PROPERTY(bool paintCursor READ paintCursor WRITE setPaintCursor NOTIFY paintCursorChanged);
	/// Stream frames instead of capturing one still. Defaults to false.
	Q_PROPERTY(bool live READ live WRITE setLive NOTIFY liveChanged);
	/// True once a frame is ready to display.
	Q_PROPERTY(bool hasContent READ hasContent NOTIFY hasContentChanged);
	/// Size of the source in pixels. Valid when @@hasContent is true.
	Q_PROPERTY(QSize sourceSize READ sourceSize NOTIFY sourceSizeChanged);
	/// Nonzero dimensions constrain the implicit size, keeping the source aspect ratio.
	Q_PROPERTY(QSizeF constraintSize READ constraintSize WRITE setConstraintSize NOTIFY constraintSizeChanged);
	/// macOS only. One of "idle", "pending", "ok", "paused", "stopped",
	/// "permission" (Screen Recording not granted), "unavailable" (source not
	/// capturable, or macOS < 14), "error".
	Q_PROPERTY(QString status READ status NOTIFY statusChanged);
	/// macOS only. Frames delivered to this view since the source was set.
	Q_PROPERTY(int frameCount READ frameCount NOTIFY frameCountChanged);
	// clang-format on

public:
	explicit ScreencopyView(QQuickItem* parent = nullptr);
	~ScreencopyView() override;
	Q_DISABLE_COPY_MOVE(ScreencopyView);

	void componentComplete() override;

	/// Capture one frame now. Restarts the stream when @@live is true.
	Q_INVOKABLE void captureFrame();
	/// End the live stream. The last frame stays displayed.
	Q_INVOKABLE void stop();

	[[nodiscard]] QObject* captureSource() const { return this->mCaptureSource; }
	void setCaptureSource(QObject* captureSource);

	[[nodiscard]] bool paintCursor() const { return this->mPaintCursor; }
	void setPaintCursor(bool paintCursor);

	[[nodiscard]] bool live() const { return this->mLive; }
	void setLive(bool live);

	[[nodiscard]] bool hasContent() const { return this->mHasContent; }
	[[nodiscard]] QSize sourceSize() const { return this->mSourceSize; }

	[[nodiscard]] QSizeF constraintSize() const { return this->mConstraintSize; }
	void setConstraintSize(QSizeF constraintSize);

	[[nodiscard]] QString status() const { return this->mStatus; }
	[[nodiscard]] int frameCount() const { return this->mFrameCount; }

	// Entry points for the capture callbacks, always on the GUI thread. Not API.
	void deliverFrame(const QImage& frame, quint64 generation);
	void streamEnded(quint64 generation, const QString& reason);
	void captureFailed(quint64 generation, qint64 code, const QString& description);

signals:
	/// The live stream ended on its own (source closed, system stopped it).
	void stopped();

	void captureSourceChanged();
	void paintCursorChanged();
	void liveChanged();
	void hasContentChanged();
	void sourceSizeChanged();
	void constraintSizeChanged();
	void statusChanged();
	void frameCountChanged();

protected:
	QSGNode* updatePaintNode(QSGNode* oldNode, UpdatePaintNodeData* data) override;
	void itemChange(ItemChange change, const ItemChangeData& value) override;

private slots:
	void onSourceDestroyed();
	void onWindowVisibleChanged();

private:
	struct Impl;

	void restart();
	void pause();
	[[nodiscard]] bool canStream() const;
	void setStatus(const QString& status);
	void setHasContent(bool hasContent);
	void setSourceSize(QSize size);
	void updateImplicitSize();
	void clearFrames();

	Impl* impl;
	QObject* mCaptureSource = nullptr;
	bool mPaintCursor = false;
	bool mLive = false;
	bool mHasContent = false;
	QSize mSourceSize = QSize(0, 0);
	// QSizeF() is -1x-1; upstream's "nonzero constrains" rule needs a real 0x0.
	QSizeF mConstraintSize = QSizeF(0, 0);
	QString mStatus = QStringLiteral("idle");
	int mFrameCount = 0;
	bool completed = false;
	bool windowVisible = false;
	QPointer<QQuickWindow> trackedWindow;

	// Written on the GUI thread, read by updatePaintNode while the GUI thread
	// is blocked in the sync phase, so no lock.
	QImage frame;
	bool frameDirty = false;
};

} // namespace qs::cocoa
