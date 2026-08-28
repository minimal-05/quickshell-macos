#include "iconimageprovider.hpp"
#include <algorithm>

#include <qcolor.h>
#include <qicon.h>
#include <qlogging.h>
#include <qpainter.h>
#include <qpixmap.h>
#include <qsize.h>
#include <qstring.h>

QPixmap
IconImageProvider::requestPixmap(const QString& id, QSize* size, const QSize& requestedSize) {
	QString iconName;
	QString fallbackName;
	QString path;

	auto splitIdx = id.indexOf("?path=");
	if (splitIdx != -1) {
		iconName = id.sliced(0, splitIdx);
		path = id.sliced(splitIdx + 6);
		path = QString("/%1/%2").arg(path, iconName.sliced(iconName.lastIndexOf('/') + 1));
	} else {
		splitIdx = id.indexOf("?fallback=");
		if (splitIdx != -1) {
			iconName = id.sliced(0, splitIdx);
			fallbackName = id.sliced(splitIdx + 10);
		} else {
			iconName = id;
		}
	}

	auto targetSize = requestedSize.isValid() ? requestedSize : QSize(100, 100);
	if (targetSize.width() == 0 || targetSize.height() == 0) targetSize = QSize(2, 2);

	auto icon = QIcon::fromTheme(iconName);
	auto pixmap = icon.isNull() ? QPixmap() : icon.pixmap(targetSize.width(), targetSize.height());

	// The requested name before the caller's fallback name. On a platform with
	// no icon theme this is the only thing that can resolve the real icon, and
	// trying it after the fallback would lose to Qt's built-in placeholder,
	// which resolves for names like "image-missing" and is not what was asked
	// for.
	if (pixmap.isNull() && IconImageProvider::fallbackLookup != nullptr) {
		pixmap = IconImageProvider::fallbackLookup(iconName, targetSize);
	}

	if (pixmap.isNull() && !fallbackName.isEmpty()) {
		icon = QIcon::fromTheme(fallbackName);
		if (!icon.isNull()) pixmap = icon.pixmap(targetSize.width(), targetSize.height());

		if (pixmap.isNull() && IconImageProvider::fallbackLookup != nullptr) {
			pixmap = IconImageProvider::fallbackLookup(fallbackName, targetSize);
		}
	}

	if (pixmap.isNull() && !path.isEmpty()) {
		icon = QPixmap(path);
		if (!icon.isNull()) pixmap = icon.pixmap(targetSize.width(), targetSize.height());
	}

	if (pixmap.isNull()) {
		qWarning() << "Could not load icon" << id << "at size" << targetSize << "from request";
		pixmap = IconImageProvider::missingPixmap(targetSize);
	}

	if (size != nullptr) *size = pixmap.size();
	return pixmap;
}

bool IconImageProvider::exists(const QString& icon) {
	if (icon.isEmpty()) return false;
	if (!QIcon::fromTheme(icon).isNull()) return true;

	// macOS ships no icon theme, so QIcon::fromTheme never matches and every
	// "does this icon exist?" test in a config would fail, sending it down to a
	// generic placeholder even though the platform lookup can resolve the real
	// application icon.
	if (IconImageProvider::fallbackLookup != nullptr) {
		return !IconImageProvider::fallbackLookup(icon, QSize(64, 64)).isNull();
	}

	return false;
}

IconImageProvider::FallbackLookup IconImageProvider::fallbackLookup = nullptr; // NOLINT

void IconImageProvider::setFallbackLookup(FallbackLookup lookup) {
	IconImageProvider::fallbackLookup = lookup;
}

QPixmap IconImageProvider::missingPixmap(const QSize& size) {
	auto width = size.width() % 2 == 0 ? size.width() : size.width() + 1;
	auto height = size.height() % 2 == 0 ? size.height() : size.height() + 1;
	width = std::max(width, 2);
	height = std::max(height, 2);

	auto pixmap = QPixmap(width, height);
	pixmap.fill(QColorConstants::Black);
	auto painter = QPainter(&pixmap);

	auto halfWidth = width / 2;
	auto halfHeight = height / 2;
	auto purple = QColor(0xd900d8);
	painter.fillRect(halfWidth, 0, halfWidth, halfHeight, purple);
	painter.fillRect(0, halfHeight, halfWidth, halfHeight, purple);
	return pixmap;
}

QString IconImageProvider::requestString(
    const QString& icon,
    const QString& path,
    const QString& fallback
) {
	auto req = "image://icon/" + icon;

	if (!path.isEmpty()) {
		req += "?path=" + path;
	}

	if (!fallback.isEmpty()) {
		req += "?fallback=" + fallback;
	}

	return req;
}
