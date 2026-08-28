pragma Singleton

// Quickshell.Bluetooth -- macOS compatibility shim (pure QML, no C++).
//
// REAL: enum values copied verbatim from
// quickshell/src/bluetooth/adapter.hpp (BluetoothAdapterState::Enum).
// Enabled/Disabled/Enabling/Disabling are all genuinely produced by the shim from
// `blueutil -p`. Blocked is never produced -- macOS has no rfkill equivalent.

import QtQuick

QtObject {
    enum Enum {
        Disabled = 0,
        Enabled = 1,
        Enabling = 2,
        Disabling = 3,
        Blocked = 4
    }

    function toString(state: int): string {
        switch (state) {
        case 1:
            return "Enabled";
        case 2:
            return "Enabling";
        case 3:
            return "Disabling";
        case 4:
            return "Blocked";
        default:
            return "Disabled";
        }
    }
}
