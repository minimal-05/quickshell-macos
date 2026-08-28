// Quickshell.Services.Notifications -- macOS compatibility shim (pure QML, no C++).
//
// Mirrors qs::service::notifications::NotificationAction
// (quickshell/src/services/notifications/notification.hpp).
//
// INERT by necessity: actions only exist on notifications received from other
// applications, and macOS gives third-party processes no way to receive those
// (see NotificationServer.qml). No instance of this type is ever produced by the
// shim. It exists so that `notification.actions.map(a => a.identifier)` in end-4's
// Notifications.qml resolves against a real type rather than throwing, and so that
// `property NotificationAction x` declarations compile.

import QtQuick

QtObject {
    property string identifier: ""
    property string text: ""

    // No-op: there is no remote application to invoke the action on.
    function invoke(): void {}
}
