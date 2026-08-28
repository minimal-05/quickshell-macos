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
// still cannot reach this server on their own.
//
// WHAT DOES WORK: notifications raised by the shell itself, and anything else that
// deliberately posts to us. Those arrive over quickshell's own IPC socket instead
// of D-Bus:
//
//     quickshell -p <config> ipc call notifications notify <app> <summary> <body> ...
//
// which is what the notify-send(1) stand-in in bin/ calls. end-4's config shells
// out to `notify-send` from a dozen places (battery warnings, recording, downloads,
// Shazam, pomodoro); routing that through here means those show up in the shell's
// own popup and notification list, the way they do on Linux, rather than in the
// macOS banner where the shell can neither style nor read them back.
//
// Everything downstream of the notification() signal is the real upstream
// contract: notifications stay tracked while `tracked` is true, dismiss()/expire()
// untrack and destroy them, and trackedNotifications.values reflects the live set.

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

    // The freedesktop wire protocol is replaced by quickshell's own IPC socket;
    // see the file header. Argument types are limited to what IpcHandler can
    // marshal, so hints collapse to the one flag notify-send actually passes.
    readonly property IpcHandler ipc: IpcHandler {
        target: "notifications"

        function notify(appName: string, summary: string, body: string, appIcon: string, urgency: int, expireTimeout: int, isTransient: bool): int {
            return server.post({
                appName: appName,
                summary: summary,
                body: body,
                appIcon: appIcon,
                urgency: urgency,
                expireTimeout: expireTimeout,
                hints: isTransient ? ({
                        "transient": true
                    }) : ({})
            });
        }

        // Mirrors org.freedesktop.Notifications.CloseNotification.
        function close(id: int): bool {
            const notif = server.trackedList.find(n => n.id === id);
            if (!notif)
                return false;
            notif.dismiss();
            return true;
        }
    }

    /// Deliver a notification as if it had arrived from a remote application.
    /// Returns its id.
    function post(params): int {
        const notif = server.notifComponent.createObject(server, {
            "id": server.nextId++,
            "appName": params.appName ?? "",
            "appIcon": params.appIcon ?? "",
            "summary": params.summary ?? "",
            "body": params.body ?? "",
            "image": params.image ?? "",
            "urgency": params.urgency ?? NotificationUrgency.Normal,
            "expireTimeout": params.expireTimeout ?? -1,
            "hints": params.hints ?? ({})
        });

        notif.closed.connect(() => server.untrack(notif));
        server.trackedList = [...server.trackedList, notif];
        server.notification(notif);

        // Upstream drops a notification the consumer never claimed.
        if (!notif.tracked)
            server.untrack(notif);

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
