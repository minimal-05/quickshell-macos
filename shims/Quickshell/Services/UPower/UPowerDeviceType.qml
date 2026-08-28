pragma Singleton

// Quickshell.Services.UPower -- macOS compatibility shim (pure QML, no C++).
//
// REAL: enum values copied verbatim from
// quickshell/src/services/upower/device.hpp (UPowerDeviceType::Enum).
// Only Battery is ever produced by this shim (macOS exposes no per-peripheral
// power devices through pmset); the rest exist so that comparisons and
// toString() calls in consumer configs resolve.

import QtQuick

QtObject {
    enum Enum {
        Unknown = 0,
        LinePower = 1,
        Battery = 2,
        Ups = 3,
        Monitor = 4,
        Mouse = 5,
        Keyboard = 6,
        Pda = 7,
        Phone = 8,
        MediaPlayer = 9,
        Tablet = 10,
        Computer = 11,
        GamingInput = 12,
        Pen = 13,
        Touchpad = 14,
        Modem = 15,
        Network = 16,
        Headset = 17,
        Speakers = 18,
        Headphones = 19,
        Video = 20,
        OtherAudio = 21,
        RemoteControl = 22,
        Printer = 23,
        Scanner = 24,
        Camera = 25,
        Wearable = 26,
        Toy = 27,
        BluetoothGeneric = 28
    }

    readonly property var _names: ["Unknown", "Line Power", "Battery", "Ups", "Monitor", "Mouse", "Keyboard", "Pda", "Phone", "Media Player", "Tablet", "Computer", "Gaming Input", "Pen", "Touchpad", "Modem", "Network", "Headset", "Speakers", "Headphones", "Video", "Other Audio", "Remote Control", "Printer", "Scanner", "Camera", "Wearable", "Toy", "Bluetooth Generic"]

    function toString(type: int): string {
        return _names[type] ?? "Unknown";
    }
}
