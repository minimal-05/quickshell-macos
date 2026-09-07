#pragma once

#include <CoreGraphics/CGImage.h>

#include <qimage.h>
#include <qpixmap.h>
#include <qsize.h>
#include <qstring.h>

namespace qs::cocoa {

/// Look up an application icon by name or bundle identifier.
///
/// Configs written for Linux ask for icons by desktop-entry name — "firefox",
/// "code", "org.kde.kolourpaint" — and Quickshell resolves those through
/// QIcon::fromTheme. macOS has no XDG icon theme, so every one of those lookups
/// fails and the shell paints the missing-texture checkerboard instead of the
/// app icons a bar or overview is supposed to show.
///
/// This asks LaunchServices for the matching application and hands back its real
/// icon. Returns a null pixmap when nothing matches, so the caller can carry on
/// to its own fallback.
QPixmap appIcon(const QString& name, const QSize& size);

/// Copy a CGImage into a premultiplied ARGB32 QImage through a bitmap context.
/// Shared by the icon lookup above and ScreencopyView's still captures.
QImage imageFromCGImage(CGImageRef image);

} // namespace qs::cocoa
