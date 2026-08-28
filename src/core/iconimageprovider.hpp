#pragma once

#include <qpixmap.h>
#include <qquickimageprovider.h>

class IconImageProvider: public QQuickImageProvider {
public:
	explicit IconImageProvider(): QQuickImageProvider(QQuickImageProvider::Pixmap) {}

	QPixmap requestPixmap(const QString& id, QSize* size, const QSize& requestedSize) override;

	static QPixmap missingPixmap(const QSize& size);

	/// Whether a name resolves to any icon, through the theme or the platform
	/// fallback. `QIcon::fromTheme` alone is not enough on a platform with no
	/// XDG icon theme, where the fallback is the only thing that ever matches.
	static bool exists(const QString& icon);

	static QString requestString(
	    const QString& icon,
	    const QString& path = QString(),
	    const QString& fallback = QString()
	);

	/// Last-resort lookup, tried when no icon theme matches.
	///
	/// Platforms without an XDG icon theme install one of these so that a
	/// desktop-entry name can still resolve to a real application icon. Returning
	/// a null pixmap means "no match" and the missing-icon placeholder is used.
	using FallbackLookup = QPixmap (*)(const QString& name, const QSize& size);
	static void setFallbackLookup(FallbackLookup lookup);

private:
	static FallbackLookup fallbackLookup;
};
