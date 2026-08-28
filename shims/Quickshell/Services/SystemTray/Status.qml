pragma Singleton

// Quickshell.Services.SystemTray -- macOS compatibility shim (pure QML, no C++).
//
// REAL: enum values copied verbatim from
// quickshell/src/services/status_notifier/item.hpp (namespace qs::service::sni::Status).
// `Status` really is the upstream QML type name -- end-4's TrayService.qml does
// `i.status !== Status.Passive`. SystemTrayStatus.qml is a same-valued alias.
//
// The enum is usable; it is the item list that is empty. See SystemTray.qml.

import QtQuick

QtObject {
    enum Enum {
        Passive = 0,
        Active = 1,
        NeedsAttention = 2
    }

    function toString(status: int): string {
        switch (status) {
        case 1:
            return "Active";
        case 2:
            return "NeedsAttention";
        default:
            return "Passive";
        }
    }
}
