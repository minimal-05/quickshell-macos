pragma Singleton

// Quickshell.Services.UPower -- macOS compatibility shim (pure QML, no C++).
//
// Mirrors qs::service::upower::UPowerQml (quickshell/src/services/upower/core.hpp).
// There is no UPower daemon on macOS; this polls pmset / ioreg / system_profiler
// instead and shapes the result into the same object graph.
//
// REAL:
//   onBattery      -- `pmset -g batt` "Now drawing from 'Battery Power'"
//   displayDevice  -- the internal battery, fully populated (see UPowerDevice.qml)
//   devices        -- an ObjectModel-SHAPED object exposing `.values`, holding the
//                     one physical internal battery. Every consumer config on disk
//                     (end-4, caelestia, dank) reaches the model exclusively through
//                     `.values`, so a JS array behind a QtObject is enough. This is
//                     NOT a QAbstractListModel and will not work as a Repeater
//                     `model:` directly -- upstream's ObjectModel would.
//
// INERT / MISSING:
//   Non-battery UPower devices (mice, keyboards, headsets, UPSes). macOS exposes no
//   per-peripheral power state, so `devices` never holds anything but the internal
//   battery, and dank's `UPower.devices.values.filter(d => d.type === Mouse)` style
//   code yields an empty list instead of throwing.
//   On a Mac with no battery, displayDevice stays ready:false / isLaptopBattery:false,
//   which is exactly what upstream does when no battery is present.

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    // --- upstream API -------------------------------------------------------

    readonly property UPowerDevice displayDevice: UPowerDevice {
        nativePath: "DisplayDevice"
        model: "Internal Battery"
    }

    readonly property QtObject devices: QtObject {
        // Not upstream API -- the physical device backing `values`. Kept on the
        // model object rather than on UPower itself so the singleton's own public
        // surface stays identical to the real one.
        readonly property UPowerDevice internalBattery: UPowerDevice {
            nativePath: "InternalBattery-0"
            model: "Internal Battery"
        }

        property var values: [internalBattery]
        readonly property int count: values.length

        function indexOf(object): int {
            return values.indexOf(object);
        }
    }

    property bool onBattery: false

    // --- macOS backing ------------------------------------------------------
    //
    // Deliberately backslash-free: this is a JS template literal, where a stray
    // "\n" or "\1" would be eaten by the JS lexer before sh ever saw it.

    readonly property string _script: `
R=$(ioreg -r -c AppleSmartBattery -w0 2>/dev/null)
pick() { echo "$R" | grep -oE '"'"$1"'" *= *[0-9]+' | grep -oE '[0-9]+$' | head -1; }
# ioreg publishes signed counters as unsigned 64-bit. Anything above 2^63 is a
# negative number, and JS cannot un-wrap it once parseInt has rounded it to a
# double, so it has to come back over the wire already signed.
sgn() { [ -n "$1" ] || return 0; command -v bc >/dev/null 2>&1 || return 0; echo "if ($1 > 9223372036854775807) { $1 - 18446744073709551616 } else { $1 }" | bc 2>/dev/null; }
echo "@@BATT"
pmset -g batt 2>/dev/null
echo "@@PMSET"
pmset -g 2>/dev/null | grep -E 'lowpowermode|highpowermode'
echo "@@IOREG"
echo "$R" | grep -oE '"(AppleRawMaxCapacity|AppleRawCurrentCapacity|DesignCapacity|Voltage|CycleCount)" *= *[0-9]+'
echo "$R" | grep -oE '"(IsCharging|ExternalConnected|FullyCharged)" *= *(Yes|No)'
echo "@@AMP"
sgn "$(pick InstantAmperage)"
echo "@@POWER"
sgn "$(pick BatteryPower)"
echo "@@HEALTH"
system_profiler SPPowerDataType -json 2>/dev/null | grep -oE 'health_maximum_capacity[^0-9]*[0-9]+' | head -1
`

    // Read by PowerProfiles.qml so Low Power Mode is polled once, not twice.
    property int _lowPowerMode: 0
    property bool _hasHighPowerMode: false

    // Line-based rather than index-based, so a command that emits no trailing
    // newline cannot run its output into the next @@MARKER.
    function _section(text: string, name: string): string {
        const out = [];
        let inside = false;
        for (const line of text.split("\n")) {
            if (line.startsWith("@@")) {
                inside = line.slice(2).split(" ")[0] === name;
                continue;
            }
            if (inside)
                out.push(line);
        }
        return out.join("\n");
    }

    // ioreg prints some keys more than once (live object then a cached copy);
    // the first occurrence is the live one.
    function _ioreg(section: string, key: string): real {
        const m = section.match(new RegExp('"' + key + '" *= *(\\d+)'));
        return m ? parseInt(m[1], 10) : 0;
    }

    // Tri-state on purpose: null means the Mac never published the key, which is
    // what selects the pmset fallback in _apply.
    function _ioregBool(section: string, key: string): var {
        const m = section.match(new RegExp('"' + key + '" *= *(Yes|No)'));
        return m ? m[1] === "Yes" : null;
    }

    function _apply(text: string): void {
        const batt = root._section(text, "BATT");
        const pmset = root._section(text, "PMSET");
        const ioreg = root._section(text, "IOREG");

        root._lowPowerMode = (pmset.match(/lowpowermode\s+(\d+)/) ?? [0, "0"])[1] | 0;
        root._hasHighPowerMode = /highpowermode/.test(pmset);

        const pct = batt.match(/(\d+)%/);
        const present = /present:\s*true/.test(batt);

        // ioreg's own booleans beat parsing pmset's prose: they flip the instant
        // the adapter is plugged in, and they tell "plugged in but held at 80% by
        // optimised charging" -- which pmset words as "AC attached; not charging",
        // indistinguishable from a real discharge to a percentage-only reader --
        // apart from actually running off the battery. pmset stays the fallback
        // for any Mac that does not publish them.
        const external = root._ioregBool(ioreg, "ExternalConnected");

        root.onBattery = external !== null ? !external : /Battery Power/.test(batt);

        let state = UPowerDeviceState.Unknown;
        if (external !== null) {
            if (external && root._ioregBool(ioreg, "FullyCharged"))
                state = UPowerDeviceState.FullyCharged;
            else if (root._ioregBool(ioreg, "IsCharging"))
                state = UPowerDeviceState.Charging;
            else if (external)
                state = UPowerDeviceState.PendingCharge;
            else
                state = UPowerDeviceState.Discharging;
        } else if (/not charging/i.test(batt))
            // "not charging" must be tested before "charging" -- it contains it.
            state = UPowerDeviceState.PendingCharge;
        else if (/finishing charge|;\s*charging/i.test(batt))
            state = UPowerDeviceState.Charging;
        else if (/;\s*charged/i.test(batt))
            state = UPowerDeviceState.FullyCharged;
        else if (/;\s*discharging/i.test(batt))
            state = UPowerDeviceState.Discharging;

        const time = batt.match(/(\d+):(\d\d)\s+remaining/);
        const seconds = time ? (parseInt(time[1], 10) * 3600 + parseInt(time[2], 10) * 60) : 0;
        const charging = state === UPowerDeviceState.Charging;

        const volts = root._ioreg(ioreg, "Voltage") / 1000;
        const rawMax = root._ioreg(ioreg, "AppleRawMaxCapacity");
        const rawCur = root._ioreg(ioreg, "AppleRawCurrentCapacity");
        const design = root._ioreg(ioreg, "DesignCapacity");
        const milliamps = Math.abs(parseInt(root._section(text, "AMP").trim(), 10) || 0);
        // Apple's own power telemetry, in milliwatts. InstantAmperage is a
        // single instantaneous current sample and reads far low against it --
        // -338 mA x 11.29 V = 3.8 W on the same poll that reports 5.7 W here,
        // which is also what SystemLoad says the machine is drawing. Amperage
        // taken alone swings the other way (-1340 mA = 15 W). Only the
        // milliwatt figure is a real measurement, so the current stays a
        // fallback for Macs that do not publish PowerTelemetryData.
        const milliwatts = Math.abs(parseInt(root._section(text, "POWER").trim(), 10) || 0);

        // Apple's own "maximum capacity" figure; falls back to raw capacity ratio.
        let health = parseFloat(root._section(text, "HEALTH").replace(/[^0-9.]/g, ""));
        if (!(health > 0) && design > 0 && rawMax > 0)
            health = rawMax / design * 100;

        // A battery that is present but whose charge did not parse must not be
        // published. Consumers read a 0% battery as "flat", and end-4's battery
        // service responds to flat-and-discharging by suspending the machine, so
        // one unreadable poll would put the system to sleep. Keeping the previous
        // reading is always the safer answer than inventing a zero.
        if (present && !pct) return;

        const percent = pct ? parseInt(pct[1], 10) : 0;

        // Order matters. `isLaptopBattery` is derived from type + powerSupply, and
        // assignment below is key-by-key, so writing those two first would make the
        // device briefly look like a real battery still carrying its initial 0%.
        // Bindings re-evaluate on that intermediate state and act on it. Every
        // measured value is therefore in place before the device claims to be a
        // battery at all.
        const fields = {
            // pmset gives an integer percent; upstream percentage is a 0.0-1.0 fraction.
            "percentage": percent / 100,
            "isPresent": present,
            "ready": present && !!pct,
            "state": state,
            "timeToEmpty": charging ? 0 : seconds,
            "timeToFull": charging ? seconds : 0,
            "energy": rawCur * volts / 1000,
            "energyCapacity": rawMax * volts / 1000,
            "changeRate": milliwatts > 0 ? milliwatts / 1000 : milliamps * volts / 1000,
            "healthPercentage": health > 0 ? health : 0,
            "healthSupported": health > 0,
            "iconName": root._iconName(state, percent, present),
            // Last, for the reason above.
            "type": UPowerDeviceType.Battery,
            "powerSupply": true
        };

        for (const target of [root.displayDevice, root.devices.internalBattery]) {
            for (const key in fields)
                target[key] = fields[key];
        }
    }

    // UPower's own IconName values, so Quickshell.iconPath() lookups in consumer
    // configs land on the same freedesktop icon names they would on Linux.
    function _iconName(state: int, percent: int, present: bool): string {
        if (!present)
            return "battery-missing-symbolic";
        if (state === UPowerDeviceState.FullyCharged)
            return "battery-full-charged-symbolic";
        const suffix = state === UPowerDeviceState.Charging ? "-charging" : "";
        if (percent > 80)
            return "battery-full" + suffix + "-symbolic";
        if (percent > 50)
            return "battery-good" + suffix + "-symbolic";
        if (percent > 20)
            return "battery-low" + suffix + "-symbolic";
        if (percent > 5)
            return "battery-caution" + suffix + "-symbolic";
        return "battery-empty" + suffix + "-symbolic";
    }

    Process {
        id: proc

        running: true
        command: ["sh", "-c", root._script]

        stdout: StdioCollector {
            onStreamFinished: root._apply(text)
        }
    }

    Timer {
        // ponytail: a plug-in shows up within one tick. `pmset -g pslog` streams
        // the change instantly; wire it up if 10s of stale bolt ever grates.
        interval: 10000
        running: true
        repeat: true
        onTriggered: proc.running = true
    }
}
