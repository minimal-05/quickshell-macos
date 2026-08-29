pragma Singleton

// Quickshell.Services.UPower -- macOS compatibility shim.
//
// Mirrors qs::service::upower::PowerProfilesQml
// (quickshell/src/services/upower/powerprofiles.hpp).
// There is no power-profiles-daemon on macOS; the values come from
// Quickshell.Cocoa.Power, which watches NSProcessInfo for Low Power Mode and
// thermal changes and re-reads the pmset preferences on every power event.
//
// REAL (read-only):
//   profile               -- Low Power Mode on maps to PowerProfile.PowerSaver.
//                            On the MacBook Pros that expose High Power Mode,
//                            that mode on maps to Performance. Otherwise Balanced.
//   hasPerformanceProfile -- true only when the machine has a High Power Mode
//                            setting at all (what `pmset -g` lists as
//                            highpowermode). False on every other Mac.
//   degradationReason     -- HighTemperature while NSProcessInfo.thermalState
//                            is serious or critical, the two levels at which
//                            macOS is actually throttling; None otherwise.
//
// INERT:
//   Writing `profile`. Changing Low Power Mode needs `sudo pmset -a lowpowermode N`
//   ("pmset must be run as root in order to modify any settings" -- pmset(1)) and
//   macOS has no unprivileged API for it. A write is accepted so consumers do not
//   error, but nothing is executed and the property snaps back to the system's
//   value, so a toggle shows the real state instead of one it is not in.
//   Deliberate: a shim must not silently try to escalate privileges.
//   holds -- permanently []. No daemon, so no application holds.

import QtQuick
import Quickshell
import Quickshell.Cocoa as Cocoa

Singleton {
    id: root

    property int profile: root._derivedProfile
    readonly property bool hasPerformanceProfile: Cocoa.Power.hasHighPowerMode
    readonly property int degradationReason: Cocoa.Power.thermalState >= Cocoa.Power.Serious
        ? PerformanceDegradationReason.HighTemperature
        : PerformanceDegradationReason.None
    readonly property var holds: []

    readonly property int _derivedProfile: Cocoa.Power.lowPowerMode ? PowerProfile.PowerSaver
        : Cocoa.Power.highPowerMode ? PowerProfile.Performance
        : PowerProfile.Balanced

    // Restore the binding a write broke, so the property keeps tracking the system.
    onProfileChanged: {
        if (root.profile === root._derivedProfile)
            return;
        Qt.callLater(() => {
            root.profile = Qt.binding(() => root._derivedProfile);
        });
    }
}
