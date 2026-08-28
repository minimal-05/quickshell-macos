pragma Singleton

// Quickshell.Services.Notifications -- macOS compatibility shim (pure QML, no C++).
//
// REAL: enum values copied verbatim from
// quickshell/src/services/notifications/notification.hpp (NotificationUrgency::Enum).
// The enum itself is genuinely usable -- consumer configs compare and store these
// values freely. It is only the *supply* of notifications that is inert; see
// NotificationServer.qml.

import QtQuick

QtObject {
    enum Enum {
        Low = 0,
        Normal = 1,
        Critical = 2
    }

    function toString(value: int): string {
        switch (value) {
        case 0:
            return "Low";
        case 2:
            return "Critical";
        default:
            return "Normal";
        }
    }
}
