pragma Singleton

// Quickshell.Services.UPower -- macOS compatibility shim.
//
// Mirrors qs::service::upower::UPowerQml (quickshell/src/services/upower/core.hpp).
// There is no UPower daemon on macOS. Everything here is a binding onto
// Quickshell.Cocoa.Power (src/cocoa/power.mm), which reads IOPowerSources and
// the AppleSmartBattery registry node in-process and is woken by IOKit's
// power-source notification, so a plug or a percent tick lands here the
// moment the kernel publishes it and nothing is ever spawned.
//
// REAL:
//   onBattery      -- IOPSGetProvidingPowerSourceType == Battery Power
//   displayDevice  -- the internal battery, fully populated (see UPowerDevice.qml)
//   devices        -- an ObjectModel-SHAPED object exposing `.values`, holding the
//                     one physical internal battery. Every consumer config on disk
//                     (end-4, caelestia, dank) reaches the model exclusively through
//                     `.values`, so a JS array behind a QtObject is enough. This is
//                     NOT a QAbstractListModel and will not work as a Repeater
//                     `model:` directly -- upstream's ObjectModel would.
//
// INERT / MISSING:
//   Non-battery UPower devices (mice, keyboards, headsets, UPSes). `devices`
//   never holds anything but the internal battery, and dank's
//   `UPower.devices.values.filter(d => d.type === Mouse)` style code yields an
//   empty list instead of throwing.
//   ponytail: Bluetooth accessories do have power sources in IOKit, but only
//   through IOPSCopyPowerSourcesByType(kIOPSSourceForAccessories), which is
//   private and unverifiable here (no accessory is paired). Ceiling: dank's
//   peripheral battery rows stay empty. Upgrade path: enumerate that list in
//   power.mm and mint a UPowerDevice per entry, type from "Accessory Category".
//   On a Mac with no battery, displayDevice stays ready:true / isPresent:false /
//   isLaptopBattery:false, which is what upstream does when no battery is present.

import QtQuick
import Quickshell
import Quickshell.Cocoa as Cocoa

Singleton {
    id: root

    // Both the display device and the physical one describe the same battery.
    // Bindings rather than assignments: the singleton is fully populated before
    // its first read and replaces every field before emitting `changed`, so no
    // consumer ever sees a battery that claims to be present at 0%.
    component NativeBattery: UPowerDevice {
        model: "Internal Battery"
        ready: Cocoa.Power.ready
        isPresent: Cocoa.Power.isPresent
        percentage: Cocoa.Power.percentage
        state: Cocoa.Power.state
        timeToEmpty: Cocoa.Power.timeToEmpty
        timeToFull: Cocoa.Power.timeToFull
        energy: Cocoa.Power.energy
        energyCapacity: Cocoa.Power.energyCapacity
        // A magnitude, matching what the real UPower daemon puts on the bus (its
        // EnergyRate is never negative) rather than the sign in the header docs --
        // end-4's BatteryPopup tests `power <= 0.01`, which only works unsigned.
        changeRate: Math.abs(Cocoa.Power.energyRate)
        healthPercentage: Cocoa.Power.healthPercentage
        healthSupported: Cocoa.Power.healthPercentage > 0
        iconName: Cocoa.Power.iconName
        type: Cocoa.Power.isPresent ? UPowerDeviceType.Battery : UPowerDeviceType.Unknown
        powerSupply: Cocoa.Power.isPresent
    }

    // --- upstream API -------------------------------------------------------

    readonly property UPowerDevice displayDevice: NativeBattery {
        nativePath: "DisplayDevice"
    }

    readonly property QtObject devices: QtObject {
        // Not upstream API -- the physical device backing `values`. Kept on the
        // model object rather than on UPower itself so the singleton's own public
        // surface stays identical to the real one.
        readonly property UPowerDevice internalBattery: NativeBattery {
            nativePath: Cocoa.Power.name || "InternalBattery-0"
        }

        property var values: [internalBattery]
        readonly property int count: values.length

        function indexOf(object): int {
            return values.indexOf(object);
        }
    }

    readonly property bool onBattery: Cocoa.Power.onBattery
}
