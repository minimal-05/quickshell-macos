// Quickshell.Services.UPower -- macOS compatibility shim (pure QML, no C++).
//
// Mirrors qs::service::upower::UPowerDevice (quickshell/src/services/upower/device.hpp).
// Upstream this type is QML_UNCREATABLE and every property is read-only; here it is a
// plain component whose properties UPower.qml writes to after parsing pmset/ioreg.
// Consumer configs only ever READ these, so a writable superset is safe.
//
// REAL (filled from `pmset -g batt`, `ioreg -c AppleSmartBattery`,
//       `system_profiler SPPowerDataType`):
//   type, powerSupply, isLaptopBattery, isPresent, ready,
//   percentage (0.0-1.0 fraction, converted from pmset's integer percent),
//   state, timeToEmpty, timeToFull (seconds), changeRate (watts),
//   healthPercentage + healthSupported, iconName, nativePath, model.
//
// APPROXIMATED:
//   energy / energyCapacity are derived from ioreg mAh * volts, so they are
//   watt-hours computed at the present terminal voltage rather than UPower's
//   design-voltage figures. Close, not identical.
//   changeRate is reported as a positive magnitude, matching what the real
//   UPower daemon puts on the bus (its EnergyRate is never negative) rather
//   than the sign convention in the header docs -- end-4's BatteryPopup tests
//   `power <= 0.01`, which only works with a magnitude.
//
// INERT: nothing here. Every member is populated for the internal battery.
// Non-battery devices simply do not exist: macOS exposes no per-peripheral
// power devices at all, so UPower.devices only ever holds the internal battery.

import QtQuick

QtObject {
    id: root

    property int type: UPowerDeviceType.Unknown
    property bool powerSupply: false
    property real energy: 0
    property real energyCapacity: 0
    property real changeRate: 0
    property real timeToEmpty: 0
    property real timeToFull: 0
    // Fraction from 0.0 to 1.0, NOT 0-100. Matches upstream.
    property real percentage: 0
    property bool isPresent: false
    property int state: UPowerDeviceState.Unknown
    // Percentage of original capacity, 0-100 (upstream maps UPower's "Capacity").
    property real healthPercentage: 0
    property bool healthSupported: false
    property string iconName: ""
    property bool isLaptopBattery: root.type === UPowerDeviceType.Battery && root.powerSupply
    property string nativePath: ""
    property string model: ""
    property bool ready: false
}
