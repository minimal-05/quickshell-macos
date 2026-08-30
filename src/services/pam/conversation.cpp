#include "conversation.hpp"

#include <qlogging.h>
#include <qloggingcategory.h>
#include <qobject.h>
#include <qstring.h>
#include <qtmetamacros.h>

#include "../../core/logcat.hpp"
#include "ipc.hpp"

#ifdef __APPLE__
#include <qbytearray.h>
#include <qeventloop.h>
#else
#include <qsocketnotifier.h>
#include <sys/signal.h>
#include <sys/wait.h>
#ifdef __FreeBSD__
#include <signal.h>
#endif
#endif

QS_LOGGING_CATEGORY(logPam, "quickshell.service.pam", QtWarningMsg);

QString PamError::toString(PamError::Enum value) {
	switch (value) {
	case StartFailed: return "Failed to start the PAM session";
	case TryAuthFailed: return "Failed to try authenticating";
	case InternalError: return "Internal error occurred";
	default: return "Invalid error";
	}
}

QString PamResult::toString(PamResult::Enum value) {
	switch (value) {
	case Success: return "Success";
	case Failed: return "Failed";
	case Error: return "Error occurred while authenticating";
	case MaxTries: return "The authentication method has no more attempts available";
	default: return "Invalid result";
	}
}

PamConversation::~PamConversation() { this->abort(); }

#ifdef __APPLE__

int PamConversation::conversationCallback(
    int msgCount,
    const pam_message** msgArray,
    pam_response** responseArray,
    void* appdata
) {
	auto* self = static_cast<PamConversation*>(appdata);

	// freed by libc so must be alloc'd by it.
	auto* responses = static_cast<pam_response*>(calloc(msgCount, sizeof(pam_response))); // NOLINT

	for (auto i = 0; i < msgCount; i++) {
		const auto* msg = msgArray[i]; // NOLINT
		auto& response = responses[i]; // NOLINT

		auto echo = msg->msg_style != PAM_PROMPT_ECHO_OFF;
		auto error = msg->msg_style == PAM_ERROR_MSG;
		auto responseRequired =
		    msg->msg_style == PAM_PROMPT_ECHO_OFF || msg->msg_style == PAM_PROMPT_ECHO_ON;

		self->haveResponse = false;
		emit self->message(QString::fromUtf8(msg->msg), error, responseRequired, echo);

		if (self->abortRequested) {
			free(responses); // NOLINT
			return PAM_CONV_ERR;
		}

		if (responseRequired) {
			// respond() may already have run synchronously off the signal above.
			if (!self->haveResponse) {
				QEventLoop loop;
				self->pendingLoop = &loop;
				loop.exec();
				self->pendingLoop = nullptr;
			}

			if (self->abortRequested) {
				free(responses); // NOLINT
				return PAM_CONV_ERR;
			}

			response.resp = strdup(self->pendingResponse.toUtf8().constData()); // NOLINT (include)
		}
	}

	*responseArray = responses;
	return PAM_SUCCESS;
}

void PamConversation::start(const QString& configDir, const QString& config, const QString& user) {
	Q_UNUSED(configDir); // macOS configs name a system PAM service, not a confdir.
	this->abortRequested = false;

	auto conv = pam_conv {.conv = &PamConversation::conversationCallback, .appdata_ptr = this};
	pam_handle_t* handle = nullptr;

	auto configBytes = config.toUtf8();
	auto userBytes = user.toUtf8();
	auto result = pam_start(configBytes.constData(), userBytes.constData(), &conv, &handle);

	if (result != PAM_SUCCESS) {
		qCWarning(logPam) << "Unable to start pam conversation:" << pam_strerror(handle, result);
		emit this->error(PamError::StartFailed);
		return;
	}

	// Blocks on this thread for the whole exchange -- the nested QEventLoop
	// above keeps Qt (and the QML UI) responsive while it does.
	result = pam_authenticate(handle, 0);

	if (this->abortRequested) {
		pam_end(handle, result);
		return;
	}

	switch (result) {
	case PAM_SUCCESS: emit this->completed(PamResult::Success); break;
	case PAM_AUTH_ERR: emit this->completed(PamResult::Failed); break;
	case PAM_MAXTRIES: emit this->completed(PamResult::MaxTries); break;
	default:
		qCWarning(logPam) << "Pam authentication error:" << pam_strerror(handle, result);
		emit this->error(PamError::TryAuthFailed);
		break;
	}

	pam_end(handle, result);
}

void PamConversation::abort() {
	this->abortRequested = true;
	if (this->pendingLoop != nullptr) this->pendingLoop->quit();
}

void PamConversation::respond(const QString& response) {
	this->pendingResponse = response;
	this->haveResponse = true;
	if (this->pendingLoop != nullptr) this->pendingLoop->quit();
}

#else

void PamConversation::start(const QString& configDir, const QString& config, const QString& user) {
	this->childPid = PamConversation::createSubprocess(&this->pipes, configDir, config, user);
	if (this->childPid == 0) {
		qCCritical(logPam) << "Failed to create pam subprocess.";
		emit this->error(PamError::InternalError);
		return;
	}

	QObject::connect(&this->notifier, &QSocketNotifier::activated, this, &PamConversation::onMessage);
	this->notifier.setSocket(this->pipes.fdIn);
	this->notifier.setEnabled(true);
}

void PamConversation::abort() {
	if (this->childPid != 0) {
		qCDebug(logPam) << "Killing subprocess for" << this;
		kill(this->childPid, SIGKILL); // NOLINT (include)
		waitpid(this->childPid, nullptr, 0);
		this->childPid = 0;
	}
}

void PamConversation::internalError() {
	if (this->childPid != 0) {
		qCDebug(logPam) << "Killing subprocess for" << this;
		kill(this->childPid, SIGKILL); // NOLINT (include)
		waitpid(this->childPid, nullptr, 0);
		this->childPid = 0;
		emit this->error(PamError::InternalError);
	}
}

void PamConversation::respond(const QString& response) {
	qCDebug(logPam) << "Sending response for" << this;
	if (!this->pipes.writeString(response.toStdString())) {
		qCCritical(logPam) << "Failed to write response to subprocess.";
		this->internalError();
	}
}

void PamConversation::onMessage() {
	{
		qCDebug(logPam) << "Got message from subprocess.";

		auto type = PamIpcEvent::Exit;

		auto ok = this->pipes.readBytes(reinterpret_cast<char*>(&type), sizeof(PamIpcEvent));

		if (!ok) goto fail;

		if (type == PamIpcEvent::Exit) {
			auto code = PamIpcExitCode::OtherError;

			ok = this->pipes.readBytes(reinterpret_cast<char*>(&code), sizeof(PamIpcExitCode));

			if (!ok) goto fail;

			qCDebug(logPam) << "Subprocess exited with code" << static_cast<int>(code);

			switch (code) {
			case PamIpcExitCode::Success: emit this->completed(PamResult::Success); break;
			case PamIpcExitCode::AuthFailed: emit this->completed(PamResult::Failed); break;
			case PamIpcExitCode::StartFailed: emit this->error(PamError::StartFailed); break;
			case PamIpcExitCode::MaxTries: emit this->completed(PamResult::MaxTries); break;
			case PamIpcExitCode::PamError: emit this->error(PamError::TryAuthFailed); break;
			case PamIpcExitCode::OtherError: emit this->error(PamError::InternalError); break;
			}

			waitpid(this->childPid, nullptr, 0);
			this->childPid = 0;
		} else if (type == PamIpcEvent::Request) {
			PamIpcRequestFlags flags {};

			ok = this->pipes.readBytes(reinterpret_cast<char*>(&flags), sizeof(PamIpcRequestFlags));

			if (!ok) goto fail;

			auto message = this->pipes.readString(&ok);

			if (!ok) goto fail;

			this->message(QString::fromUtf8(message), flags.error, flags.responseRequired, flags.echo);
		} else {
			qCCritical(logPam) << "Unexpected message from subprocess.";
			goto fail;
		}
	}
	return;

fail:
	qCCritical(logPam) << "Failed to read subprocess request.";
	this->internalError();
}

#endif
