#include "appicon.hpp"

#import <AppKit/AppKit.h>

#include <qhash.h>
#include <qimage.h>
#include <qpixmap.h>
#include <qsize.h>
#include <qstring.h>

namespace qs::cocoa {

namespace {

/// Resolve a name to an application bundle path.
///
/// Names arrive in several shapes: a bundle id ("org.mozilla.firefox"), a
/// display name as yabai reports it ("Firefox", "Visual Studio Code"), or a
/// lowercased desktop-entry stem ("firefox", "code"). Try each in turn.
NSString* bundlePathFor(const QString& name) {
	if (name.isEmpty()) return nil;

	auto* workspace = NSWorkspace.sharedWorkspace;
	auto* raw = name.toNSString();

	if (name.contains('.')) {
		auto* url = [workspace URLForApplicationWithBundleIdentifier:raw];
		if (url != nil) return url.path;
	}

	// Exact display name, then title-cased, which covers "firefox" -> "Firefox".
	for (NSString* candidate in @[raw, raw.capitalizedString]) {
		auto* path = [workspace fullPathForApplication:candidate];
		if (path != nil) return path;
	}

	return nil;
}

QPixmap toPixmap(NSImage* image, const QSize& size) {
	if (image == nil) return {};

	// The best representation for that size, rendered once; no TIFF/PNG
	// round trip through NSBitmapImageRep.
	auto rect = NSMakeRect(0, 0, size.width(), size.height());
	auto* cg = [image CGImageForProposedRect:&rect context:nil hints:nil];
	return cg != nullptr ? QPixmap::fromImage(imageFromCGImage(cg)) : QPixmap();
}

} // namespace

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

QPixmap appIcon(const QString& name, const QSize& size) {
	// Icon lookups happen per window per repaint in some configs, and asking
	// LaunchServices every time is far too slow, so remember what we resolved.
	static auto cache = QHash<QString, QPixmap>();

	auto key = QStringLiteral("%1@%2x%3").arg(name).arg(size.width()).arg(size.height());
	auto cached = cache.constFind(key);
	if (cached != cache.constEnd()) return *cached;

	QPixmap pixmap;

	@autoreleasepool {
		auto* path = bundlePathFor(name);
		if (path != nil) {
			pixmap = toPixmap([NSWorkspace.sharedWorkspace iconForFile:path], size);
		}
	}

	// A null result is cached too: a name that does not name an application will
	// not start naming one, and the miss is the expensive part.
	cache.insert(key, pixmap);
	return pixmap;
}

} // namespace qs::cocoa
