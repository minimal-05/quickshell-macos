// Acceptance probe for Quickshell.Cocoa.Power, the IOKit battery singleton.
//   bin/qs-test tests/_probe_power.qml -- power check == ok
//   bin/qs-test tests/_probe_power.qml -- power percentage     (compare to pmset -g batt)
//   bin/qs-test tests/_probe_power.qml -- power state          (charging / discharging / charged / pending)
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Cocoa as Cocoa

ShellRoot {
    property int changes: 0

    Connections {
        target: Cocoa.Power
        function onChanged() { changes++; }
    }

    IpcHandler {
        target: "power"

        function check(): string {
            const p = Cocoa.Power;
            const fails = [];
            if (!p.ready) fails.push("not ready");
            if (!p.isPresent) return "no-battery";
            if (!(p.percentage > 0 && p.percentage <= 1)) fails.push(`percentage ${p.percentage}`);
            if (![Cocoa.Power.Charging, Cocoa.Power.Discharging, Cocoa.Power.FullyCharged, Cocoa.Power.PendingCharge].includes(p.state)) fails.push(`state ${p.state}`);
            if (p.state === Cocoa.Power.Discharging && (!p.onBattery || p.externalConnected)) fails.push("discharging but not on battery");
            if (p.state !== Cocoa.Power.Discharging && p.onBattery) fails.push("on battery but not discharging");
            if (!(p.energyCapacity > 0 && p.energy > 0 && p.energy <= p.energyCapacity * 1.05)) fails.push(`energy ${p.energy}/${p.energyCapacity}`);
            if (!(p.energyFullDesign >= p.energyCapacity)) fails.push(`design ${p.energyFullDesign} < capacity ${p.energyCapacity}`);
            if (!(p.voltage > 5 && p.voltage < 30)) fails.push(`voltage ${p.voltage}`);
            if (p.state === Cocoa.Power.Charging && p.energyRate < 0) fails.push("charging with negative rate");
            if (p.state === Cocoa.Power.Discharging && p.energyRate > 0) fails.push("discharging with positive rate");
            if (!(p.temperature > 0 && p.temperature < 80)) fails.push(`temperature ${p.temperature}`);
            if (!(p.cycleCount > 0)) fails.push(`cycleCount ${p.cycleCount}`);
            if (!(p.healthPercentage > 30 && p.healthPercentage <= 100)) fails.push(`health ${p.healthPercentage}`);
            if (!/^battery-.*-symbolic$/.test(p.iconName)) fails.push(`iconName ${p.iconName}`);
            if (p.name !== "InternalBattery-0") fails.push(`name ${p.name}`);
            if (p.timeToEmpty > 0 && p.state !== Cocoa.Power.Discharging) fails.push("timeToEmpty while not discharging");
            if (p.timeToFull > 0 && p.state !== Cocoa.Power.Charging) fails.push("timeToFull while not charging");
            if (![0, 1, 2, 3].includes(p.thermalState)) fails.push(`thermalState ${p.thermalState}`);
            return fails.length ? "fail: " + fails.join(", ") : "ok";
        }

        function percentage(): string {
            return String(Math.round(Cocoa.Power.percentage * 100));
        }

        // pmset's words, so a shell test can compare directly.
        function state(): string {
            switch (Cocoa.Power.state) {
            case Cocoa.Power.Charging: return "charging";
            case Cocoa.Power.Discharging: return "discharging";
            case Cocoa.Power.FullyCharged: return "charged";
            case Cocoa.Power.PendingCharge: return "AC attached; not charging";
            default: return "unknown";
            }
        }

        function lowPowerMode(): string { return Cocoa.Power.lowPowerMode ? "1" : "0"; }

        function dump(): string {
            const p = Cocoa.Power;
            const out = {};
            for (const k of ["ready", "isPresent", "onBattery", "externalConnected", "percentage", "state", "timeToEmpty", "timeToFull", "energy", "energyCapacity", "energyFullDesign", "energyRate", "voltage", "current", "temperature", "cycleCount", "designCycleCount", "healthPercentage", "healthCondition", "iconName", "name", "model", "serial", "lowPowerMode", "highPowerMode", "hasHighPowerMode", "thermalState"])
                out[k] = p[k];
            out.changes = changes;
            return JSON.stringify(out);
        }
    }
}
