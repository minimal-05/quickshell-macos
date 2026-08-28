pragma Singleton

// Quickshell.Bluetooth -- macOS compatibility shim (pure QML, no C++).
//
// REAL: enum values copied verbatim from
// quickshell/src/bluetooth/device.hpp (BluetoothDeviceState::Enum).
// All four states are genuinely produced: Connected/Disconnected come from
// blueutil's poll, Connecting/Disconnecting are set optimistically by
// BluetoothDevice.connect()/disconnect() until the next poll confirms.

import QtQuick

QtObject {
    enum Enum {
        Disconnected = 0,
        Connected = 1,
        Disconnecting = 2,
        Connecting = 3
    }

    function toString(state: int): string {
        switch (state) {
        case 1:
            return "Connected";
        case 2:
            return "Disconnecting";
        case 3:
            return "Connecting";
        default:
            return "Disconnected";
        }
    }
}
