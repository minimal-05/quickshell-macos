// Runnable check for the shim's pmset/ioreg -> UPowerDevice translation.
//
//   node shims/test-upower.mjs
//
// UPower.qml is QML, but _apply() and its helpers are plain JS over a string,
// so the real functions are lifted out of the shipped file and run against a
// stub device. Testing a copy of the logic would guard nothing.

import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const src = readFileSync(new URL("./Quickshell/Services/UPower/UPower.qml", import.meta.url), "utf8");

const start = src.indexOf("    function _section(");
assert.notEqual(start, -1, "_section not found — did the shim move?");
const end = src.indexOf("    Process {", start);
assert.notEqual(end, -1, "no Process block after the helpers");

// QML type annotations are the only thing in here node cannot parse. No object
// key in the block is named after a type, so stripping them is safe.
const body = src.slice(start, end).replace(/: (string|real|int|bool|var|void)\b/g, "");

const UPowerDeviceState = { Unknown: 0, Charging: 1, Discharging: 2, Empty: 3, FullyCharged: 4, PendingCharge: 5 };
const UPowerDeviceType = { Unknown: 0, Battery: 2 };

function makeRoot() {
    const device = () => ({});
    const root = { displayDevice: device(), devices: { internalBattery: device() }, onBattery: false, _lowPowerMode: 0, _hasHighPowerMode: false };
    const fns = new Function("root", "UPowerDeviceState", "UPowerDeviceType", `${body}
        return { _section, _ioreg, _ioregBool, _apply, _iconName };`)(root, UPowerDeviceState, UPowerDeviceType);
    Object.assign(root, fns);
    return root;
}

// One poll, assembled the way the shell script emits it.
const poll = ({ batt, ioreg = "", amp = "", power = "", health = "81" }) =>
    `@@BATT\n${batt}\n@@PMSET\n lowpowermode 0\n@@IOREG\n${ioreg}\n@@AMP\n${amp}\n@@POWER\n${power}\n@@HEALTH\nhealth_maximum_capacity" : "${health}\n`;

const io = (ext, charging, full, extra = '"Voltage" = 11438\n"AppleRawMaxCapacity" = 3385\n"AppleRawCurrentCapacity" = 1964\n"DesignCapacity" = 4382') =>
    `${extra}\n"ExternalConnected" = ${ext}\n"FullyCharged" = ${full}\n"IsCharging" = ${charging}`;

const S = UPowerDeviceState;
const cases = [
    ["on battery",
     { batt: " -InternalBattery-0 (id=1)\t61%; discharging; 4:00 remaining present: true", ioreg: io("No", "No", "No"), amp: "-670", power: "-7663" },
     { state: S.Discharging, onBattery: true, changeRate: 7.663, percentage: 0.61, timeToEmpty: 14400, timeToFull: 0 }],

    ["charging",
     { batt: " -InternalBattery-0 (id=1)\t61%; charging; 1:30 remaining present: true", ioreg: io("Yes", "Yes", "No"), amp: "2100", power: "24000" },
     { state: S.Charging, onBattery: false, changeRate: 24, timeToFull: 5400, timeToEmpty: 0 }],

    // The case pmset alone gets wrong: optimised charging holds at 80% and
    // words it as "AC attached; not charging", which is not a discharge.
    ["plugged in but held",
     { batt: " -InternalBattery-0 (id=1)\t80%; AC attached; not charging present: true", ioreg: io("Yes", "No", "No"), power: "0" },
     { state: S.PendingCharge, onBattery: false }],

    ["full on AC",
     { batt: " -InternalBattery-0 (id=1)\t100%; charged; 0:00 remaining present: true", ioreg: io("Yes", "No", "Yes"), power: "0" },
     { state: S.FullyCharged, onBattery: false, percentage: 1 }],

    // A Mac that publishes none of the booleans falls back to pmset's prose.
    ["no ioreg booleans, charging",
     { batt: " -InternalBattery-0 (id=1)\t61%; charging; 1:30 remaining present: true", power: "24000" },
     { state: S.Charging, onBattery: false }],

    ["no ioreg booleans, discharging",
     { batt: "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t61%; discharging; 4:00 remaining present: true" },
     { state: S.Discharging, onBattery: true }],

    // No PowerTelemetryData: fall back to current x voltage (0.670 A * 11.438 V).
    ["wattage fallback",
     { batt: " -InternalBattery-0 (id=1)\t61%; discharging; 4:00 remaining present: true", ioreg: io("No", "No", "No"), amp: "-670" },
     { changeRate: 7.663 }],
];

for (const [name, input, expected] of cases) {
    const root = makeRoot();
    root._apply(poll(input));
    for (const [key, want] of Object.entries(expected)) {
        const got = key === "onBattery" ? root.onBattery : root.displayDevice[key];
        if (typeof want === "number" && !Number.isInteger(want))
            assert.ok(Math.abs(got - want) < 0.02, `${name}: ${key} was ${got}, wanted ~${want}`);
        else
            assert.equal(got, want, `${name}: ${key}`);
    }
}

// An unreadable poll must never publish 0%, which end-4 reads as flat and
// answers by suspending the machine.
const stale = makeRoot();
stale._apply(poll({ batt: " -InternalBattery-0 (id=1)\t61%; discharging; 4:00 remaining present: true", ioreg: io("No", "No", "No"), power: "-7663" }));
stale._apply(poll({ batt: " -InternalBattery-0 (id=1)\tno reading present: true" }));
assert.equal(stale.displayDevice.percentage, 0.61, "a garbled poll must keep the last good reading");

console.log(`${cases.length + 1} checks passed`);
