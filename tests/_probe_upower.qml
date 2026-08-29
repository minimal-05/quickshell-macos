// Acceptance probe for the UPower shim. Asserts the shape end-4's Battery
// service reads: displayDevice.percentage in (0,1], a real state enum, one
// internal battery in devices.values.
//   bin/qs-test tests/_probe_upower.qml -- upower check == ok
//   bin/qs-test tests/_probe_upower.qml -- upower percentage      (compare to pmset -g batt)
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

ShellRoot {
    // A QML singleton is instantiated on first reference, so touch it at load:
    // otherwise the first poll only starts with the first ipc call and the
    // reply is "not-ready" for the next 30 s.
    Component.onCompleted: void UPower.displayDevice

    IpcHandler {
        target: "upower"

        function check(): string {
            const d = UPower.displayDevice;
            if (!d.ready)
                return "not-ready";
            if (!(d.percentage > 0 && d.percentage <= 1))
                return "bad-percentage " + d.percentage;
            if (![UPowerDeviceState.Charging, UPowerDeviceState.Discharging, UPowerDeviceState.FullyCharged, UPowerDeviceState.PendingCharge].includes(d.state))
                return "bad-state " + d.state;
            if (!d.isLaptopBattery)
                return "not-laptop-battery";
            if (UPower.devices.values.length !== 1 || UPower.devices.values[0].percentage !== d.percentage)
                return "bad-devices";
            if (d.state === UPowerDeviceState.Discharging && !UPower.onBattery)
                return "onBattery-mismatch";
            if (!(d.energyCapacity > 0) || !(d.energy > 0))
                return "bad-energy";
            if (![PowerProfile.PowerSaver, PowerProfile.Balanced, PowerProfile.Performance].includes(PowerProfiles.profile))
                return "bad-profile";
            return "ok";
        }

        function percentage(): string {
            return String(Math.round(UPower.displayDevice.percentage * 100));
        }

        function state(): string {
            return UPowerDeviceState.toString(UPower.displayDevice.state);
        }

        function dump(): string {
            const d = UPower.displayDevice;
            const out = {};
            for (const k of ["ready", "percentage", "state", "timeToEmpty", "timeToFull", "energy", "energyCapacity", "changeRate", "healthPercentage", "healthSupported", "iconName", "isLaptopBattery"])
                out[k] = d[k];
            out.onBattery = UPower.onBattery;
            out.profile = PowerProfiles.profile;
            return JSON.stringify(out);
        }
    }
}
