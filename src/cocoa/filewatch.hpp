#pragma once

#include <qlist.h>
#include <qobject.h>
#include <qqmlintegration.h>
#include <qstring.h>
#include <qtmetamacros.h>

class QSocketNotifier;

namespace qs::cocoa {

/// Reports a change to any of a fixed set of files in one directory the
/// moment the kernel sees it.
///
/// FileView { watchChanges: true } goes through QFileSystemWatcher, which on
/// macOS is FSEvents: fseventsd batches and delivers roughly 400 ms after a
/// touch (measured on this machine, five touches in a row: 375-427 ms). That
/// is fine for a config file and useless for yabai's signal files, whose
/// whole point is that a Space switch reaches the bar before the animation
/// ends. kqueue's EVFILT_VNODE has no such batching: a touch shows up on the
/// next event-loop turn.
///
/// The directory itself is watched too, so files that appear after the
/// watcher starts (the signal files are created by bin/qs-yabai-signals,
/// which may still be running) are picked up without anyone calling back.
class FileWatcher: public QObject {
	Q_OBJECT;
	QML_ELEMENT;
	/// Directory holding the files. Nothing is watched until it is set.
	Q_PROPERTY(QString directory READ directory WRITE setDirectory NOTIFY directoryChanged);
	/// File names inside @@directory to watch. Missing ones are retried when
	/// the directory changes.
	Q_PROPERTY(QList<QString> files READ files WRITE setFiles NOTIFY filesChanged);

public:
	explicit FileWatcher(QObject* parent = nullptr): QObject(parent) {}
	~FileWatcher() override;
	Q_DISABLE_COPY_MOVE(FileWatcher);

	[[nodiscard]] QString directory() const { return this->mDirectory; }
	void setDirectory(const QString& directory);

	[[nodiscard]] QList<QString> files() const { return this->mFiles; }
	void setFiles(const QList<QString>& files);

signals:
	void directoryChanged();
	void filesChanged();
	/// A watched file was written to, touched, or replaced. `name` is the
	/// entry of @@files it happened to.
	void changed(const QString& name);

private slots:
	void onReadable();

private:
	void rebuild();
	void closeAll();

	QString mDirectory;
	QList<QString> mFiles;
	int mKqueue = -1;
	int mDirFd = -1;
	QList<int> mFds;   // parallel to mFdNames
	QList<QString> mFdNames;
	QSocketNotifier* mNotifier = nullptr;
};

} // namespace qs::cocoa
