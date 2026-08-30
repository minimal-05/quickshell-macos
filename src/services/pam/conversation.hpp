#pragma once

#include <qloggingcategory.h>
#include <qobject.h>
#include <qqmlintegration.h>
#include <qtclasshelpermacros.h>
#include <qtmetamacros.h>
#include <qtypes.h>

#include "../../core/logcat.hpp"
#include "ipc.hpp"

#ifdef __APPLE__
#include <security/pam_appl.h>
class QEventLoop;
#else
#include <qsocketnotifier.h>
#endif

QS_DECLARE_LOGGING_CATEGORY(logPam);

///! The result of an authentication.
/// See @@PamContext.completed(s).
class PamResult: public QObject {
	Q_OBJECT;
	QML_ELEMENT;
	QML_SINGLETON;

public:
	enum Enum : quint8 {
		/// Authentication was successful.
		Success = 0,
		/// Authentication failed.
		Failed = 1,
		/// An error occurred while trying to authenticate.
		Error = 2,
		/// The authentication method ran out of tries and should not be used again.
		MaxTries = 3,
	};
	Q_ENUM(Enum);

	Q_INVOKABLE static QString toString(PamResult::Enum value);
};

///! An error that occurred during an authentication.
/// See @@PamContext.error(s).
class PamError: public QObject {
	Q_OBJECT;
	QML_ELEMENT;
	QML_SINGLETON;

public:
	enum Enum : quint8 {
		/// Failed to start the pam session.
		StartFailed = 1,
		/// Failed to try to authenticate the user.
		/// This is not the same as the user failing to authenticate.
		TryAuthFailed = 2,
		/// An error occurred inside quickshell's pam interface.
		InternalError = 3,
	};
	Q_ENUM(Enum);

	Q_INVOKABLE static QString toString(PamError::Enum value);
};

// PAM has no way to abort a running module except when it sends a message,
// meaning aborts for things like fingerprint scanners
// and hardware keys don't actually work without aborting the process...
// so we have a subprocess.
//
// Not on Apple: see the comment on the CMakeLists SOURCES for why fork() is
// unsafe there. This runs PAM in-process instead, which sharpens the same
// limitation rather than introducing a new one -- abort() can still only
// interrupt a step already blocked waiting on respond(), never a callback
// wedged inside a module's own blocking read. In practice that never comes up
// here: this platform's lock screen only ever drives the "screensaver"
// service (pam_opendirectory), which never blocks outside a conv exchange.
class PamConversation: public QObject {
	Q_OBJECT;

public:
	explicit PamConversation(QObject* parent): QObject(parent) {}
	~PamConversation() override;
	Q_DISABLE_COPY_MOVE(PamConversation);

public:
	void start(const QString& configDir, const QString& config, const QString& user);

	void abort();
	void respond(const QString& response);

signals:
	void completed(PamResult::Enum result);
	void error(PamError::Enum error);
	void message(QString message, bool messageChanged, bool isError, bool responseRequired);

#ifdef __APPLE__
private:
	static int conversationCallback(
	    int msgCount,
	    const pam_message** msgArray,
	    pam_response** responseArray,
	    void* appdata
	);

	// Set while a conv exchange is waiting on respond() to unblock it.
	QEventLoop* pendingLoop = nullptr;
	QString pendingResponse;
	// Config code paths (this codebase's included) respond synchronously, from
	// inside the handler for `message`, before conversationCallback ever gets
	// to start the loop above -- so respond() has to work whether or not the
	// loop exists yet.
	bool haveResponse = false;
	bool abortRequested = false;
#else
private slots:
	void onMessage();

private:
	static pid_t createSubprocess(
	    PamIpcPipes* pipes,
	    const QString& configDir,
	    const QString& config,
	    const QString& user
	);

	void internalError();

	pid_t childPid = 0;
	PamIpcPipes pipes;
	QSocketNotifier notifier {QSocketNotifier::Read};
#endif
};
