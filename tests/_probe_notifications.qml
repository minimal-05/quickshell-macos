// Acceptance probe for the Quickshell.Services.Notifications shim (P0-09).
// Driven by tests/notifications.sh; every IPC function returns a string so
// the driver can assert on it from bash/python.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications

ShellRoot {
    id: root
    property var events: []
    property var byId: ({})

    function describe(n) {
        if (!n)
            return null;
        return {
            id: n.id,
            appName: n.appName,
            appIcon: n.appIcon,
            summary: n.summary,
            body: n.body,
            urgency: n.urgency,
            urgencyName: NotificationUrgency.toString(n.urgency),
            actions: n.actions.map(a => a.identifier),
            actionTexts: n.actions.map(a => a.text),
            image: n.image,
            transient: n.transient,
            resident: n.resident,
            desktopEntry: n.desktopEntry,
            expireTimeout: n.expireTimeout,
            hints: n.hints,
            tracked: n.tracked
        };
    }

    NotificationServer {
        id: server
        actionsSupported: true
        imageSupported: true
        persistenceSupported: true
        onNotification: notification => {
            // Untracked test: an appName of "drop" is deliberately never claimed.
            if (notification.appName !== "drop")
                notification.tracked = true;
            root.byId[notification.id] = notification;
            root.events = [...root.events, "notification " + notification.id];
            notification.closed.connect(reason => {
                root.events = [...root.events, "closed " + notification.id + " " + reason];
            });
        }
    }

    IpcHandler {
        target: "probe"

        function last(): string {
            const list = server.trackedNotifications.values;
            return JSON.stringify(root.describe(list[list.length - 1]));
        }
        function get(id: int): string {
            return JSON.stringify(root.describe(server.trackedNotifications.values.find(n => n.id === id)));
        }
        function count(): string {
            return String(server.trackedNotifications.count);
        }
        function events(): string {
            return root.events.join("\n");
        }
        function invoke(id: int, index: int): string {
            const n = server.trackedNotifications.values.find(n => n.id === id);
            if (!n || index >= n.actions.length)
                return "no such action";
            n.actions[index].invoke();
            return "invoked";
        }
        function untrack(id: int): string {
            const n = server.trackedNotifications.values.find(n => n.id === id);
            if (!n)
                return "no such notification";
            n.tracked = false;
            return "untracked";
        }
        function dismiss(id: int): string {
            const n = server.trackedNotifications.values.find(n => n.id === id);
            if (!n)
                return "no such notification";
            n.dismiss();
            return "dismissed";
        }
    }
}
