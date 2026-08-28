pragma Singleton

// Quickshell.Services.SystemTray -- macOS compatibility shim (pure QML, no C++).
//
// REAL: enum values copied verbatim from
// quickshell/src/services/status_notifier/item.hpp (namespace qs::service::sni::Category).
// `Category` is the upstream QML type name; SystemTrayCategory.qml is a same-valued alias.

import QtQuick

QtObject {
    enum Enum {
        Hardware = 0,
        SystemServices = 1,
        ApplicationStatus = 2,
        Communications = 3
    }

    function toString(category: int): string {
        switch (category) {
        case 0:
            return "Hardware";
        case 1:
            return "SystemServices";
        case 3:
            return "Communications";
        default:
            return "ApplicationStatus";
        }
    }
}
