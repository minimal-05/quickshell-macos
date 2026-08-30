pragma Singleton

// Quickshell.Services.UPower -- macOS compatibility shim (pure QML, no C++).
//
// REAL: the enum values are copied verbatim from
// quickshell/src/services/upower/device.hpp (UPowerDeviceState::Enum), so
// `UPowerDeviceState.Charging` etc. compare correctly against the values
// UPower.qml binds from Quickshell.Cocoa.Power. toString() matches upstream's strings.
//
// Both `UPowerDeviceState.Charging` and `UPowerDeviceState.Enum.Charging`
// resolve, same as the C++ Q_ENUM.

import QtQuick

QtObject {
    enum Enum {
        Unknown = 0,
        Charging = 1,
        Discharging = 2,
        Empty = 3,
        FullyCharged = 4,
        PendingCharge = 5,
        PendingDischarge = 6
    }

    function toString(status: int): string {
        switch (status) {
        case 1:
            return "Charging";
        case 2:
            return "Discharging";
        case 3:
            return "Empty";
        case 4:
            return "Fully charged";
        case 5:
            return "Pending charge";
        case 6:
            return "Pending discharge";
        default:
            return "Unknown";
        }
    }
}
