pragma Singleton

// Quickshell.Services.Notifications -- macOS compatibility shim (pure QML, no C++).
//
// REAL: enum values copied verbatim from
// quickshell/src/services/notifications/notification.hpp
// (NotificationCloseReason::Enum -- note it starts at 1, there is no 0).
// Emitted by Notification.expire() / dismiss(), which do work; it is only the
// arrival of notifications that cannot happen on macOS.

import QtQuick

QtObject {
    enum Enum {
        Expired = 1,
        Dismissed = 2,
        CloseRequested = 3
    }

    function toString(value: int): string {
        switch (value) {
        case 1:
            return "Expired";
        case 2:
            return "Dismissed";
        case 3:
            return "Close requested";
        default:
            return "Unknown";
        }
    }
}
