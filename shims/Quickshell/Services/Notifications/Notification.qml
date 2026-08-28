// Quickshell.Services.Notifications -- macOS compatibility shim (pure QML, no C++).
//
// Mirrors qs::service::notifications::Notification
// (quickshell/src/services/notifications/notification.hpp). Upstream this is
// QML_UNCREATABLE and populated from the org.freedesktop.Notifications D-Bus
// service; here it is a plain component with the same member names and defaults,
// constructed by NotificationServer.post() for notifications delivered over
// quickshell's IPC socket (see NotificationServer.qml for why D-Bus has no macOS
// equivalent and what does arrive instead).
//
// expire() and dismiss() are the real thing: they clear `tracked` and emit
// closed(), which the server uses to untrack and destroy the notification exactly
// as upstream does.
//
// Note: no `id: ` object id is declared in this file on purpose. The upstream type
// has a `id` PROPERTY (the notification id), which QML lets us declare, but an
// object id of the same name would shadow it inside this file.

import QtQuick

QtObject {
    property int id: 0
    property bool tracked: false
    readonly property bool lastGeneration: false
    property real expireTimeout: -1
    property string appName: ""
    property string appIcon: ""
    property string summary: ""
    property string body: ""
    property int urgency: NotificationUrgency.Normal
    // `var` rather than `list<NotificationAction>` so that .map()/.filter() work --
    // end-4's Notifications.qml calls notification.actions.map(...) directly.
    property var actions: []
    property bool hasActionIcons: false
    property bool resident: false
    // NOTE: upstream also has a `transient` property. `transient` is a reserved
    // word in the QML grammar, so a pure-QML shim CANNOT declare it -- the file
    // fails to parse ("Expected token `identifier'"). Reading `notification.transient`
    // therefore yields undefined rather than false. Both are falsy, and end-4 reads
    // `hints.transient` instead (hints is a plain JS object, so that works), but it
    // is a genuine and unfixable-in-QML gap.
    property string desktopEntry: ""
    property string image: ""
    property bool hasInlineReply: false
    property string inlineReplyPlaceholder: ""
    property var hints: ({})

    signal closed(reason: int)

    function expire(): void {
        tracked = false;
        closed(NotificationCloseReason.Expired);
    }

    function dismiss(): void {
        tracked = false;
        closed(NotificationCloseReason.Dismissed);
    }

    // No-op: notifications posted locally have no remote sender to reply to, and
    // macOS exposes no other application's notifications to reply to either.
    function sendInlineReply(replyText: string): void {}
}
