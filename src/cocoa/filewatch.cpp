#include "filewatch.hpp"

#include <fcntl.h>
#include <sys/event.h>
#include <sys/time.h>
#include <unistd.h>

#include <qdebug.h>
#include <qlogging.h>
#include <qsocketnotifier.h>

namespace qs::cocoa {

FileWatcher::~FileWatcher() { this->closeAll(); }

void FileWatcher::setDirectory(const QString& directory) {
	if (directory == this->mDirectory) return;
	this->mDirectory = directory;
	emit this->directoryChanged();
	this->rebuild();
}

void FileWatcher::setFiles(const QList<QString>& files) {
	if (files == this->mFiles) return;
	this->mFiles = files;
	emit this->filesChanged();
	this->rebuild();
}

void FileWatcher::closeAll() {
	delete this->mNotifier;
	this->mNotifier = nullptr;

	for (auto fd: this->mFds) ::close(fd);
	this->mFds.clear();
	this->mFdNames.clear();

	if (this->mDirFd >= 0) ::close(this->mDirFd);
	this->mDirFd = -1;

	if (this->mKqueue >= 0) ::close(this->mKqueue);
	this->mKqueue = -1;
}

void FileWatcher::rebuild() {
	this->closeAll();
	if (this->mDirectory.isEmpty() || this->mFiles.isEmpty()) return;

	this->mKqueue = ::kqueue();
	if (this->mKqueue < 0) {
		qWarning() << "FileWatcher: kqueue() failed for" << this->mDirectory;
		return;
	}

	auto add = [this](int fd, unsigned int flags) {
		struct kevent ev {};
		EV_SET(&ev, fd, EVFILT_VNODE, EV_ADD | EV_CLEAR, flags, 0, nullptr);
		return ::kevent(this->mKqueue, &ev, 1, nullptr, 0, nullptr) == 0;
	};

	// O_EVTONLY: a descriptor for watching only, which does not pin the
	// volume the way an ordinary open does.
	auto dir = this->mDirectory.toUtf8();
	this->mDirFd = ::open(dir.constData(), O_EVTONLY);
	if (this->mDirFd >= 0 && !add(this->mDirFd, NOTE_WRITE | NOTE_DELETE | NOTE_RENAME)) {
		::close(this->mDirFd);
		this->mDirFd = -1;
	}

	for (const auto& name: this->mFiles) {
		auto path = (this->mDirectory + '/' + name).toUtf8();
		auto fd = ::open(path.constData(), O_EVTONLY);
		if (fd < 0) continue; // created later: the directory watch retries
		if (!add(fd, NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_DELETE | NOTE_RENAME)) {
			::close(fd);
			continue;
		}
		this->mFds.append(fd);
		this->mFdNames.append(name);
	}

	this->mNotifier = new QSocketNotifier(this->mKqueue, QSocketNotifier::Read, this);
	QObject::connect(this->mNotifier, &QSocketNotifier::activated, this, &FileWatcher::onReadable);
}

void FileWatcher::onReadable() {
	struct kevent events[32]; // NOLINT
	const struct timespec zero {0, 0};
	auto n = ::kevent(this->mKqueue, nullptr, 0, events, 32, &zero);
	if (n <= 0) return;

	bool relist = false;
	QList<QString> fired;

	for (int i = 0; i < n; i++) {
		auto fd = static_cast<int>(events[i].ident);
		if (fd == this->mDirFd) {
			relist = true;
			continue;
		}
		auto idx = this->mFds.indexOf(fd);
		if (idx < 0) continue;
		// A replaced or deleted file leaves a stale descriptor behind; the
		// directory watch has already queued a rebuild for the new one.
		if (events[i].fflags & (NOTE_DELETE | NOTE_RENAME)) relist = true;
		if (!fired.contains(this->mFdNames[idx])) fired.append(this->mFdNames[idx]);
	}

	// Rebuild before emitting: a handler may tear this object down.
	if (relist || this->mFds.length() < this->mFiles.length()) this->rebuild();

	for (const auto& name: fired) emit this->changed(name);
}

} // namespace qs::cocoa
