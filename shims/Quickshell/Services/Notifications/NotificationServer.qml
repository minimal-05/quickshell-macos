// Quickshell.Services.Notifications -- macOS compatibility shim (pure QML, no C++).
//
// Mirrors qs::service::notifications::NotificationServerQml
// (quickshell/src/services/notifications/qml.hpp).
//
// WHAT CANNOT WORK: on Linux this type claims the org.freedesktop.Notifications
// D-Bus name and every application in the session then hands ITS notifications to
// quickshell. macOS has no equivalent. Notifications reach the system Notification
// Center over a private XPC interface, and there is no public API -- and no
// unprivileged private one -- that lets a third-party process register as a
// notification host or observe other applications' notifications.
// (NSDistributedNotificationCenter is unrelated: it carries app-defined IPC
// messages, not user notifications.) Notifications raised by OTHER apps therefore
// only reach this server through bin/qs-notify-bridge, which replays the
// Notification Center store.
//
// WHAT DOES WORK: notifications raised by the shell itself, and anything else that
// deliberately posts to us. Those arrive over quickshell's own IPC socket instead
// of D-Bus, as the freedesktop Notify() call with the two structured arguments
// (actions, hints) folded into one JSON string, the only shape IpcHandler can
// marshal:
//
//     quickshell -p <config> ipc call notifications notifyv2 \
//         <appName> <replacesId> <appIcon> <summary> <body> <expireTimeout> <extraJson>
//
//     extraJson = {"actions": [["id", "text"], ...],
//                  "hints":   {"urgency": 2, "transient": true, "image-path": "...", ...},
//                  "reply":   "<fifo or file the sender reads action/close events from>",
//                  "wait":    true}          // sender wants the close event too
//
// which is what the notify-send(1) stand-in in bin/ calls. end-4's config shells
// out to `notify-send` from a dozen places (battery warnings, recording, downloads,
// Shazam, pomodoro); routing that through here means those show up in the shell's
// own popup and notification list, the way they do on Linux, rather than in the
// macOS banner where the shell can neither style nor read them back.
//
// Everything downstream of the notification() signal is the real upstream
// contract: replacesId updates the existing notification in place without a new
// signal, notifications stay tracked while `tracked` is true, dismiss()/expire()/
// `tracked = false` untrack and destroy them, actions invoke back to the sender,
// and trackedNotifications.values reflects the live set.

import QtQuick
import Quickshell.Io

QtObject {
    id: server

    // --- upstream defaults, all writable -----------------------------------
    property bool keepOnReload: true
    property bool persistenceSupported: false
    property bool bodySupported: true
    property bool bodyMarkupSupported: false
    property bool bodyHyperlinksSupported: false
    property bool bodyImagesSupported: false
    property bool actionsSupported: false
    property bool actionIconsSupported: false
    property bool imageSupported: false
    property bool inlineReplySupported: false
    property var extraHints: []

    // ObjectModel-shaped, exposing `.values` the way every consumer config reads
    // it (end-4: trackedNotifications.values.findIndex(...)).
    readonly property QtObject trackedNotifications: QtObject {
        readonly property var values: server.trackedList
        readonly property int count: server.trackedList.length

        function indexOf(object): int {
            return server.trackedList.indexOf(object);
        }
    }

    signal notification(notif: Notification)

    // --- local delivery ----------------------------------------------------

    // Upstream ids come from D-Bus and restart at 1 each run; matching that keeps
    // end-4's idOffset collision handling meaningful.
    property int nextId: 1
    property var trackedList: []

    readonly property Component notifComponent: Component {
        Notification {}
    }

    readonly property IpcHandler ipc: IpcHandler {
        target: "notifications"

        // Mirrors org.freedesktop.Notifications.Notify; see the file header for
        // the JSON argument.
        function notifyv2(appName: string, replacesId: int, appIcon: string, summary: string, body: string, expireTimeout: int, extra: string): int {
            let x = {};
            if (extra !== "") {
                try {
                    x = JSON.parse(extra);
                } catch (e) {
                    console.warn("notifications: ignoring malformed extra JSON:", e.message);
                }
            }
            return server.deliver(replacesId, {
                appName: appName,
                appIcon: appIcon,
                summary: summary,
                body: body,
                expireTimeout: expireTimeout,
                actions: x.actions ?? [],
                hints: x.hints ?? ({}),
                replyPath: x.reply ?? "",
                replyOnClose: !!x.wait
            });
        }

        // The pre-v2 call; kept so a caller built against it keeps working.
        function notify(appName: string, summary: string, body: string, appIcon: string, urgency: int, expireTimeout: int, isTransient: bool): int {
            return server.deliver(0, {
                appName: appName,
                appIcon: appIcon,
                summary: summary,
                body: body,
                expireTimeout: expireTimeout,
                hints: {
                    "urgency": urgency,
                    "transient": isTransient
                }
            });
        }

        // Mirrors org.freedesktop.Notifications.CloseNotification.
        function close(id: int): bool {
            const notif = server.trackedList.find(n => n.id === id);
            if (!notif)
                return false;
            notif.close(NotificationCloseReason.CloseRequested);
            return true;
        }
    }

    /// Deliver a notification as if it had arrived from a remote application.
    /// Returns its id. Kept for QML callers; the IPC path goes through deliver().
    function post(params): int {
        return server.deliver(params.replacesId ?? 0, params);
    }

    // Transcription of NotificationServer::Notify (server.cpp): a replacesId
    // naming a tracked notification updates it in place and returns its id with
    // no new notification() signal; anything else is a fresh notification the
    // consumer must claim (tracked = true) during the signal or lose.
    function deliver(replacesId: int, params): int {
        let notif = replacesId > 0 ? server.trackedList.find(n => n.id === replacesId) : undefined;
        const old = !!notif;
        if (!notif) {
            notif = server.notifComponent.createObject(server, {
                "id": server.nextId++
            });
        }
        notif.updateProperties(params);
        if (old)
            return notif.id;

        notif.closed.connect(() => server.untrack(notif));
        server.trackedList = [...server.trackedList, notif];
        server.notification(notif);

        // Upstream drops a notification the consumer never claimed and tells the
        // sender it was closed (its default close reason is Dismissed).
        if (!notif.tracked) {
            if (notif.replyOnClose)
                notif.sendReply("closed", String(NotificationCloseReason.Dismissed));
            server.untrack(notif);
        }
        return notif.id;
    }

    function untrack(notif): void {
        const index = server.trackedList.indexOf(notif);
        if (index === -1)
            return;
        const remaining = server.trackedList.slice();
        remaining.splice(index, 1);
        server.trackedList = remaining;
        // Upstream destroys closed notifications, which is what makes a consumer's
        // `notification` property go null. destroy() is deferred to the next event
        // loop turn, so calling it from inside a closed() handler is safe.
        notif.destroy();
    }
}
