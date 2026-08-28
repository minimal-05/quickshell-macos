pragma Singleton

// Quickshell.Services.UPower -- macOS compatibility shim (pure QML, no C++).
//
// REAL: enum values copied verbatim from
// quickshell/src/services/upower/powerprofiles.hpp.
// INERT: nothing on macOS ever produces LapDetected or HighTemperature --
// PowerProfiles.degradationReason is permanently None. Declared so that
// consumer configs (caelestia, dank) that read and stringify it still load.

import QtQuick

QtObject {
    enum Enum {
        None = 0,
        LapDetected = 1,
        HighTemperature = 2
    }

    function toString(reason: int): string {
        switch (reason) {
        case 1:
            return "Lap detected";
        case 2:
            return "High temperature";
        default:
            return "None";
        }
    }
}
