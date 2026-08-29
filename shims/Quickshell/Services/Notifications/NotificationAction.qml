// Quickshell.Services.Notifications -- macOS compatibility shim (pure QML, no C++).
//
// Mirrors qs::service::notifications::NotificationAction
// (quickshell/src/services/notifications/notification.hpp). Instances are
// created by Notification.updateProperties() from the action pairs the sender
// put in the IPC call (notify-send -A id=text), and invoke() hands the
// identifier back to that sender through the notification's reply path; see
// Notification.qml. As upstream, invoking dismisses the notification unless it
// is resident.

import QtQuick

QtObject {
    property string identifier: ""
    property string text: ""
    property var notification: null

    function invoke(): void {
        if (notification)
            notification.invokeAction(identifier);
    }
}
