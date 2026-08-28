pragma Singleton

// Quickshell.Services.UPower -- macOS compatibility shim (pure QML, no C++).
//
// REAL: enum values copied verbatim from
// quickshell/src/services/upower/powerprofiles.hpp (PowerProfile::Enum).
// See PowerProfiles.qml for how far the macOS side of this actually goes.

import QtQuick

QtObject {
    enum Enum {
        PowerSaver = 0,
        Balanced = 1,
        Performance = 2
    }

    function toString(profile: int): string {
        switch (profile) {
        case 0:
            return "Power Saver";
        case 2:
            return "Performance";
        default:
            return "Balanced";
        }
    }
}
