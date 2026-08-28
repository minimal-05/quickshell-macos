#include "appicon.hpp"

#import <AppKit/AppKit.h>

#include <qbytearray.h>
#include <qhash.h>
#include <qimage.h>
#include <qpixmap.h>
#include <qsize.h>
#include <qstring.h>

namespace qs::cocoa {

namespace {

NSString* toNSString(const QString& s) {
	return [NSString stringWithUTF8String:s.toUtf8().constData()];
}

/// Resolve a name to an application bundle path.
///
/// Names arrive in several shapes: a bundle id ("org.mozilla.firefox"), a
/// display name as yabai reports it ("Firefox", "Visual Studio Code"), or a
/// lowercased desktop-entry stem ("firefox", "code"). Try each in turn.
NSString* bundlePathFor(const QString& name) {
	if (name.isEmpty()) return nil;

	auto* workspace = NSWorkspace.sharedWorkspace;
	auto* raw = toNSString(name);

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

	auto target = NSMakeSize(size.width(), size.height());
	image.size = target;

	auto* rep = [NSBitmapImageRep
	    imageRepWithData:[image TIFFRepresentation]];
	if (rep == nil) return {};

	auto* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
	if (png == nil) return {};

	auto bytes = QByteArray(static_cast<const char*>(png.bytes), static_cast<qsizetype>(png.length));

	QPixmap pixmap;
	if (!pixmap.loadFromData(bytes, "PNG")) return {};
	return pixmap;
}

} // namespace

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
