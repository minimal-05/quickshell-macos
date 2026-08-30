#include "clipboard.hpp"

#include <sys/file.h>
#include <unistd.h>

#include <qbytearray.h>
#include <qclipboard.h>
#include <qcryptographichash.h>
#include <qdir.h>
#include <qfile.h>
#include <qguiapplication.h>
#include <qlogging.h>
#include <qobject.h>
#include <qsavefile.h>
#include <qstring.h>
#include <qstringlist.h>
#include <qtimer.h>

#import <AppKit/AppKit.h>

namespace qs::cocoa {

namespace {

// The history store bin/cliphist reads. One directory:
//   index.tsv   one line per entry, oldest first: `id \t sha1(content) \t preview`
//   blobs/<id>  the content, UTF-8 text or PNG
//   seq         the last id handed out, so ids never repeat across a wipe
//   lock        flock() target; every quickshell process records, and one copy
//               noticed by several of them must not become several entries
// The preview follows cliphist's shape (`[[ binary data 12 KiB png 640x480 ]]`
// for images, whitespace-collapsed text otherwise) because end-4 pattern
// matches on it. Only this file allocates ids; the CLI deletes and wipes.
QString historyDir() {
	auto dir = qEnvironmentVariable("QS_CLIPHIST_DIR");
	if (dir.isEmpty()) dir = QDir::homePath() + "/Library/Application Support/quickshell/cliphist";
	return dir;
}

int historyMax() {
	bool ok = false;
	auto max = qEnvironmentVariable("QS_CLIPHIST_MAX").toInt(&ok);
	return ok && max > 0 ? max : 500;
}

QString humanSize(qsizetype bytes) {
	if (bytes < 1024) return QString("%1 B").arg(bytes);
	if (bytes < 1024 * 1024) return QString("%1 KiB").arg(bytes / 1024);
	return QString("%1 MiB").arg(static_cast<double>(bytes) / (1024.0 * 1024.0), 0, 'f', 1);
}

void writeFile(const QString& path, const QByteArray& data) {
	QSaveFile file(path);
	if (!file.open(QIODevice::WriteOnly)) {
		qWarning() << "Clipboard: cannot write" << path << file.errorString();
		return;
	}
	file.write(data);
	file.commit();
}

void store(const QByteArray& content, const QString& preview) {
	auto dir = historyDir();
	if (!QDir().mkpath(dir + "/blobs")) {
		qWarning() << "Clipboard: cannot create" << dir;
		return;
	}

	auto lockFd = ::open((dir + "/lock").toUtf8().constData(), O_CREAT | O_RDWR | O_CLOEXEC, 0644);
	if (lockFd < 0 || ::flock(lockFd, LOCK_EX) != 0) {
		qWarning() << "Clipboard: cannot lock" << dir;
		if (lockFd >= 0) ::close(lockFd);
		return;
	}

	auto hash = QString::fromLatin1(QCryptographicHash::hash(content, QCryptographicHash::Sha1).toHex());

	QStringList lines;
	QFile index(dir + "/index.tsv");
	if (index.open(QIODevice::ReadOnly | QIODevice::Text)) {
		lines = QString::fromUtf8(index.readAll()).split('\n', Qt::SkipEmptyParts);
	}

	// Already the newest entry: the same copy seen by another process, or the
	// user copying the same thing again. Anything older with the same content
	// moves to the top, as cliphist does.
	if (!lines.isEmpty() && lines.last().section('\t', 1, 1) == hash) {
		::close(lockFd);
		return;
	}
	for (auto i = lines.size() - 1; i >= 0; --i) {
		if (lines[i].section('\t', 1, 1) != hash) continue;
		QFile::remove(dir + "/blobs/" + lines[i].section('\t', 0, 0));
		lines.removeAt(i);
	}

	quint64 id = 0;
	QFile seq(dir + "/seq");
	if (seq.open(QIODevice::ReadOnly)) id = QString::fromLatin1(seq.readAll()).trimmed().toULongLong();
	++id;
	writeFile(dir + "/seq", QByteArray::number(id));
	writeFile(dir + "/blobs/" + QString::number(id), content);

	lines.append(QString("%1\t%2\t%3").arg(id).arg(hash, preview));
	auto max = historyMax();
	while (lines.size() > max) {
		QFile::remove(dir + "/blobs/" + lines.first().section('\t', 0, 0));
		lines.removeFirst();
	}
	writeFile(dir + "/index.tsv", (lines.join('\n') + '\n').toUtf8());

	::close(lockFd);
}

// Snapshot what is on the pasteboard into the store. Text wins over an image
// when both are offered (a copied web selection carries both), matching what
// wl-paste hands cliphist. Concealed and transient entries are what password
// managers mark their copies with; they are never recorded.
void record(NSPasteboard* pasteboard) {
	NSArray<NSPasteboardType>* types = pasteboard.types;
	if ([types containsObject:@"org.nspasteboard.ConcealedType"]
	    || [types containsObject:@"org.nspasteboard.TransientType"])
		return;

	if (NSString* text = [pasteboard stringForType:NSPasteboardTypeString]) {
		auto content = QString::fromNSString(text);
		if (content.trimmed().isEmpty()) return;
		store(content.toUtf8(), content.left(4096).simplified().left(100));
		return;
	}

	NSData* png = [pasteboard dataForType:NSPasteboardTypePNG];
	NSBitmapImageRep* rep = nil;
	if (png != nil) {
		rep = [NSBitmapImageRep imageRepWithData:png];
	} else if (NSData* tiff = [pasteboard dataForType:NSPasteboardTypeTIFF]) {
		rep = [NSBitmapImageRep imageRepWithData:tiff];
		png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
	}
	if (png == nil || rep == nil) return;

	auto content = QByteArray::fromNSData(png);
	store(
	    content,
	    QString("[[ binary data %1 png %2x%3 ]]").arg(humanSize(content.size())).arg(rep.pixelsWide).arg(rep.pixelsHigh)
	);
}

class ClipboardWatch: public QObject {
public:
	ClipboardWatch() {
		this->mLastCount = [NSPasteboard generalPasteboard].changeCount;

		// Qt's own path: a QML `Quickshell.clipboardText = x`, or the sync Qt
		// does when the app activates. Both already reach QML; only the
		// history needs updating, and the counter must move on so the next
		// poll does not report the same change a second time.
		QObject::connect(
		    qGuiApp->clipboard(),
		    &QClipboard::changed,
		    this,
		    [this](QClipboard::Mode mode) {
			    if (mode != QClipboard::Clipboard || this->mEmitting) return;
			    this->notice(false);
		    }
		);

		this->mTimer.setInterval(250);
		QObject::connect(&this->mTimer, &QTimer::timeout, this, [this]() { this->notice(true); });
		this->mTimer.start();
	}

private:
	void notice(bool emitChange) {
		auto* pasteboard = [NSPasteboard generalPasteboard];
		auto count = pasteboard.changeCount;
		if (count == this->mLastCount) return;
		this->mLastCount = count;

		record(pasteboard);

		if (!emitChange) return;
		// QClipboard::changed is a public signal; raising it here runs the same
		// QuickshellGlobal slot a Qt-originated change would, and the read that
		// follows in QML is fresh because the cocoa clipboard syncs on access.
		this->mEmitting = true;
		emit qGuiApp->clipboard()->changed(QClipboard::Clipboard);
		this->mEmitting = false;
	}

	QTimer mTimer;
	NSInteger mLastCount = 0;
	bool mEmitting = false;
};

} // namespace

void startClipboardWatch() {
	static ClipboardWatch* watch = nullptr;
	if (watch == nullptr) watch = new ClipboardWatch();
}

} // namespace qs::cocoa
