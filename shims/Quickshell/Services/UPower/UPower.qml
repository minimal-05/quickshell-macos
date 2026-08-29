pragma Singleton

// Quickshell.Services.UPower -- macOS compatibility shim (pure QML, no C++).
//
// Mirrors qs::service::upower::UPowerQml (quickshell/src/services/upower/core.hpp).
// There is no UPower daemon on macOS; this reads the AppleSmartBattery node out
// of the IOKit registry and shapes it into the same object graph.
//
// REAL:
//   onBattery      -- ioreg ExternalConnected, which flips the instant the
//                     adapter is plugged in
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
//
// COST: the steady state is one `ioreg -r -c AppleSmartBattery -w0` every 30 s,
// parsed here -- 0.03 spawns/s. Two things ioreg does not carry are read at
// startup, then once an hour and whenever the adapter is plugged or unplugged:
// Apple's own "Maximum Capacity" health figure (`system_profiler SPPowerDataType`)
// and Low Power Mode (`pmset -g`, for PowerProfiles.qml). Low Power Mode has
// separate battery and AC settings, so the plug event is the one moment the
// effective value changes without the user opening System Settings.
// ponytail: a plug-in shows up within one 30 s tick, so the bolt can lag by
// that much. Upgrade path: P1-09 (IOPSNotificationCreateRunLoopSource in
// src/cocoa) makes it event-driven with zero spawns.

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

    // Read by PowerProfiles.qml so Low Power Mode is polled once, not twice.
    property int _lowPowerMode: 0
    property bool _hasHighPowerMode: false

    // Apple's "Maximum Capacity" percentage from system_profiler; 0 until read.
    property real _health: 0

    // ioreg prints the node's own properties one per line as `"Key" = value`,
    // while nested dictionaries (BatteryData, PowerTelemetryData) are squashed
    // onto a single line as `"Key"=value`. Matching the spaced form anchored to a
    // line keeps a nested "Voltage" or "DesignCapacity" from shadowing the live
    // top-level one.
    function _top(text: string, key: string): string {
        const m = text.match(new RegExp('^\\s*"' + key + '" = (.+)$', "m"));
        return m ? m[1].trim() : "";
    }

    function _num(text: string, key: string): real {
        return root._signed(root._top(text, key));
    }

    // Tri-state: null means the Mac never published the key.
    function _bool(text: string, key: string): var {
        const v = root._top(text, key);
        return v === "Yes" ? true : v === "No" ? false : null;
    }

    // A key inside a nested dictionary, e.g. BatteryPower in PowerTelemetryData.
    function _nested(text: string, key: string): real {
        const m = text.match(new RegExp('"' + key + '"=(\\d+)'));
        return m ? root._signed(m[1]) : 0;
    }

    // ioreg publishes signed counters as unsigned 64-bit: a discharge current of
    // -338 mA arrives as 18446744073709551278. A double cannot hold that exactly
    // (the last eleven bits are gone by the time parseInt returns), so the
    // subtraction from 2^64 is done on the decimal digits in two halves that
    // each fit. 2^64 = 18446744073 * 1e9 + 709551616.
    function _signed(digits: string): real {
        if (!/^\d+$/.test(digits))
            return 0;
        const negative = digits.length === 20 || (digits.length === 19 && digits >= "9223372036854775808");
        if (!negative)
            return parseInt(digits, 10);
        const split = digits.length - 9;
        let hi = 18446744073 - parseInt(digits.slice(0, split), 10);
        let lo = 709551616 - parseInt(digits.slice(split), 10);
        if (lo < 0) {
            lo += 1000000000;
            hi -= 1;
        }
        return -(hi * 1000000000 + lo);
    }

    function _apply(text: string): void {
        const present = root._bool(text, "BatteryInstalled") === true;
        const external = root._bool(text, "ExternalConnected");
        const wasOnBattery = root.onBattery;
        root.onBattery = external === false;

        let state = UPowerDeviceState.Unknown;
        if (external !== null) {
            // FullyCharged is tested first: a full battery on AC reports
            // IsCharging = No too, and "plugged in but held at 80% by optimised
            // charging" is the PendingCharge case, which a percentage-only
            // reader could not tell from a real discharge.
            if (external && root._bool(text, "FullyCharged"))
                state = UPowerDeviceState.FullyCharged;
            else if (root._bool(text, "IsCharging"))
                state = UPowerDeviceState.Charging;
            else if (external)
                state = UPowerDeviceState.PendingCharge;
            else
                state = UPowerDeviceState.Discharging;
        }
        const charging = state === UPowerDeviceState.Charging;

        // CurrentCapacity/MaxCapacity are percent on Apple silicon (Max is
        // always 100) and mAh on Intel; the ratio is the charge either way, and
        // pmset -g batt rounds the same ratio for its percentage.
        const max = root._num(text, "MaxCapacity");
        const cur = root._num(text, "CurrentCapacity");
        const rawMax = root._num(text, "AppleRawMaxCapacity");
        const rawCur = root._num(text, "AppleRawCurrentCapacity");
        const design = root._num(text, "DesignCapacity");
        const volts = root._num(text, "Voltage") / 1000;
        let fraction = max > 0 ? cur / max : rawMax > 0 ? rawCur / rawMax : 0;
        fraction = Math.max(0, Math.min(1, fraction));

        // Minutes; 65535 is the firmware's "not yet estimated".
        let minutes = root._num(text, "TimeRemaining");
        if (minutes === 0 || minutes >= 65535)
            minutes = root._num(text, charging ? "AvgTimeToFull" : "AvgTimeToEmpty");
        const seconds = minutes > 0 && minutes < 65535 ? minutes * 60 : 0;

        // Apple's own power telemetry, in milliwatts. InstantAmperage is a
        // single instantaneous current sample and reads far low against it
        // (-338 mA x 11.29 V = 3.8 W on the same poll that reports 5.7 W here,
        // which is also what SystemLoad says the machine is drawing), so the
        // current stays a fallback for Macs that do not publish
        // PowerTelemetryData.
        const milliwatts = Math.abs(root._nested(text, "BatteryPower"));
        const milliamps = Math.abs(root._num(text, "InstantAmperage"));

        // Apple's "Maximum Capacity" figure; falls back to raw capacity ratio.
        let health = root._health;
        if (!(health > 0) && design > 0 && rawMax > 0)
            health = rawMax / design * 100;

        // A battery that is present but whose charge did not parse must not be
        // published. Consumers read a 0% battery as "flat", and end-4's battery
        // service responds to flat-and-discharging by suspending the machine, so
        // one unreadable poll would put the system to sleep. Keeping the previous
        // reading is always the safer answer than inventing a zero.
        if (present && !(fraction > 0))
            return;

        // Order matters. `isLaptopBattery` is derived from type + powerSupply, and
        // assignment below is key-by-key, so writing those two first would make the
        // device briefly look like a real battery still carrying its initial 0%.
        // Bindings re-evaluate on that intermediate state and act on it. Every
        // measured value is therefore in place before the device claims to be a
        // battery at all.
        const fields = {
            "percentage": fraction,
            "isPresent": present,
            "ready": present,
            "state": state,
            "timeToEmpty": charging ? 0 : seconds,
            "timeToFull": charging ? seconds : 0,
            "energy": rawCur * volts / 1000,
            "energyCapacity": rawMax * volts / 1000,
            "changeRate": milliwatts > 0 ? milliwatts / 1000 : milliamps * volts / 1000,
            "healthPercentage": health > 0 ? health : 0,
            "healthSupported": health > 0,
            "iconName": root._iconName(state, Math.round(fraction * 100), present),
            // Last, for the reason above.
            "type": present ? UPowerDeviceType.Battery : UPowerDeviceType.Unknown,
            "powerSupply": present
        };

        for (const target of [root.displayDevice, root.devices.internalBattery]) {
            for (const key in fields)
                target[key] = fields[key];
        }

        if (root.displayDevice.ready && wasOnBattery !== root.onBattery)
            pmsetProc.running = true;
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
        id: ioregProc

        running: true
        command: ["ioreg", "-r", "-c", "AppleSmartBattery", "-w0"]

        stdout: StdioCollector {
            onStreamFinished: root._apply(text)
        }
    }

    Process {
        id: healthProc

        running: true
        command: ["system_profiler", "SPPowerDataType", "-json"]

        stdout: StdioCollector {
            onStreamFinished: {
                // "81%" under sppower_battery_health_info; the JSON is nested a
                // level deeper than a regex cares about.
                const m = text.match(/"sppower_battery_health_maximum_capacity"\s*:\s*"?(\d+)/);
                root._health = m ? parseInt(m[1], 10) : 0;
            }
        }
    }

    Process {
        id: pmsetProc

        running: true
        command: ["pmset", "-g"]

        stdout: StdioCollector {
            onStreamFinished: {
                root._lowPowerMode = (text.match(/lowpowermode\s+(\d+)/) ?? [0, "0"])[1] | 0;
                root._hasHighPowerMode = /highpowermode/.test(text);
            }
        }
    }

    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: ioregProc.running = true
    }

    Timer {
        interval: 3600000
        running: true
        repeat: true
        onTriggered: {
            healthProc.running = true;
            pmsetProc.running = true;
        }
    }
}
