pragma Singleton

// Quickshell.Services.UPower -- macOS compatibility shim (pure QML, no C++).
//
// Mirrors qs::service::upower::PowerProfilesQml
// (quickshell/src/services/upower/powerprofiles.hpp).
// There is no power-profiles-daemon on macOS.
//
// REAL (read-only):
//   profile               -- driven by `pmset -g` lowpowermode: 1 maps to
//                            PowerProfile.PowerSaver, 0 to PowerProfile.Balanced.
//                            On Macs that expose highpowermode (16"/high-power
//                            MacBook Pros) a value of 1 there maps to Performance.
//   hasPerformanceProfile -- true only when `pmset -g` lists highpowermode at all.
//                            False on every other Mac, including this one.
//
// INERT:
//   Writing `profile`. Changing Low Power Mode needs `sudo pmset -a lowpowermode N`
//   ("pmset must be run as root in order to modify any settings" -- pmset(1)) and
//   macOS has no unprivileged API for it. A write is accepted so consumers do not
//   error, but nothing is executed and the property snaps back to the polled
//   value, so a toggle shows the system's real state instead of one it is not in.
//   Deliberate: a shim must not silently try to escalate privileges.
//   degradationReason -- permanently PerformanceDegradationReason.None. macOS
//                        reports thermal pressure but never as a profile degradation.
//   holds             -- permanently []. No daemon, so no application holds.

import QtQuick
import Quickshell

Singleton {
    id: root

    property int profile: root._derivedProfile
    readonly property bool hasPerformanceProfile: UPower._hasHighPowerMode
    readonly property int degradationReason: PerformanceDegradationReason.None
    readonly property var holds: []

    readonly property int _derivedProfile: UPower._lowPowerMode === 1 ? PowerProfile.PowerSaver : PowerProfile.Balanced

    // Restore the binding a write broke, so the property keeps tracking pmset.
    onProfileChanged: {
        if (root.profile === root._derivedProfile)
            return;
        Qt.callLater(() => {
            root.profile = Qt.binding(() => root._derivedProfile);
        });
    }
}
