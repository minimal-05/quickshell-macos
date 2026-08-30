pragma Singleton

// Quickshell.Bluetooth -- macOS compatibility shim (pure QML, no C++).
//
// Mirrors the `Bluetooth` singleton (quickshell/src/bluetooth/bluez.hpp, BluezQml).
// There is no BlueZ on macOS; this drives blueutil and system_profiler instead and
// shapes the result into the same object graph.
//
// REAL:
//   defaultAdapter / adapters -- one adapter, matching the one Bluetooth controller
//                                every Mac has. enabled and discoverable are read
//                                AND written through blueutil; discovering runs a
//                                real inquiry scan.
//   devices                   -- every paired device, every connected device, and
//                                anything an inquiry scan turned up. Names,
//                                addresses, connect/disconnect and pair/unpair are
//                                all genuinely wired.
//
// DEGRADED WITHOUT blueutil:
//   blueutil (`brew install blueutil`) is NOT required. Without it the module falls
//   back to `system_profiler SPBluetoothDataType -json` alone, which is READ-ONLY:
//   the device list, names, types and battery levels still populate, but the radio
//   cannot be toggled, discovery cannot be started, and connect/disconnect/pair
//   become no-ops. Nothing throws; see the `_hasBlueutil` guard in _exec().
//
// DELIBERATE DEVIATION:
//   defaultAdapter is never null, even before the first poll completes. Upstream
//   returns null when no adapter exists, but end-4's SidebarRightContent.qml does an
//   unguarded `Bluetooth.defaultAdapter.enabled = true`, and every Mac has a
//   controller anyway. `adapters.values` stays empty until hardware is confirmed,
//   so end-4's BluetoothStatus.available check still behaves correctly.
//
// The models are ObjectModel-SHAPED, exposing `.values` -- which is how every
// consumer config on disk reads them. They are NOT QAbstractListModels, so unlike
// upstream they cannot be passed to a Repeater as `model:` directly.
//
// COST: the steady state is a single `blueutil -p -d --paired --format json`
// every 30 s (0.03 spawns/s): blueutil processes its arguments in order and
// prints all three answers in one run, and the paired listing already carries
// `connected`, so the separate --connected call is gone. system_profiler, which
// only contributes device type and battery level, runs at startup, every 10
// minutes, and whenever the set of connected devices changes -- a battery
// level is only interesting for a device that just connected. Every write the
// shim makes (power, connect, pair, ...) re-polls immediately on completion, so
// the UI never waits out the interval for its own action.
// ponytail: a device connecting from the other end (AirPods opened) shows up
// within 30 s. Upgrade path: P1-10 (IOBluetooth connect/disconnect
// notifications) makes it event-driven with zero spawns.

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    // --- upstream API -------------------------------------------------------

    readonly property BluetoothAdapter defaultAdapter: BluetoothAdapter {
        devices: root.devices
    }

    readonly property QtObject adapters: QtObject {
        property var values: []
        readonly property int count: values.length

        function indexOf(object): int {
            return values.indexOf(object);
        }
    }

    readonly property QtObject devices: QtObject {
        property var values: []
        readonly property int count: values.length

        function indexOf(object): int {
            return values.indexOf(object);
        }
    }

    // --- internal state -----------------------------------------------------

    property bool _hasBlueutil: false
    // address -> BluetoothDevice, so objects are reused across polls and bindings
    // in consumer delegates do not churn.
    property var _objects: ({})
    // address -> record, from each source. Merged in _rebuild().
    property var _fromBlueutil: ({})
    property var _fromProfiler: ({})
    property var _fromInquiry: ({})
    property var _queue: []
    // Sorted, joined addresses of the connected set as of the last poll.
    property string _connectedKey: ""

    // blueutil prints "28-11-a5-dc-e8-b4"; system_profiler prints
    // "28:11:A5:DC:E8:B4". BlueZ uses the latter, so normalise to that.
    function _normalize(address: string): string {
        return (address ?? "").replace(/-/g, ":").toUpperCase();
    }

    function _json(text: string): var {
        try {
            return JSON.parse(text);
        } catch (e) {
            return null;
        }
    }

    // --- polling ------------------------------------------------------------

    // One blueutil run answers `-p`, `-d` and `--paired` in argument order, so
    // the output is "<power>\n<discoverable>\n[...json...]" -- the JSON array
    // has no trailing newline of its own. The array is cut out by its brackets
    // and whatever is left is the two flags, so the parse does not depend on
    // blueutil's ordering.
    function _applyPoll(text: string): void {
        // Nothing at all, not even "[]": the binary is missing. Quickshell has
        // already logged the failed start once; stop asking so it does not log
        // it every 30 s, and let system_profiler carry the read-only fallback.
        if (text.trim().length === 0) {
            root._hasBlueutil = false;
            pollTimer.running = false;
            root._rebuild();
            return;
        }
        root._hasBlueutil = true;

        const start = text.indexOf("[");
        const end = text.lastIndexOf("]");
        const list = start !== -1 && end > start ? root._json(text.slice(start, end + 1)) ?? [] : [];
        const flags = (start !== -1 ? text.slice(0, start) + text.slice(end + 1) : text).trim().split(/\s+/);

        const adapter = root.defaultAdapter;
        adapter._updating = true;
        adapter.enabled = flags[0] === "1";
        adapter.discoverable = flags[1] === "1";
        adapter.state = adapter.enabled ? BluetoothAdapterState.Enabled : BluetoothAdapterState.Disabled;
        adapter._updating = false;

        if (root.adapters.values.length === 0)
            root.adapters.values = [adapter];

        const records = {};
        const connected = [];
        for (const entry of list) {
            const address = root._normalize(entry.address);
            records[address] = {
                "address": address,
                "name": entry.name ?? address,
                "paired": entry.paired ?? true,
                "connected": entry.connected ?? false
            };
            if (entry.connected)
                connected.push(address);
        }

        root._fromBlueutil = records;
        root._rebuild();

        const key = connected.sort().join(",");
        if (key !== root._connectedKey) {
            root._connectedKey = key;
            profilerProc.running = true;
        }
    }

    function _applyProfiler(text: string): void {
        const parsed = root._json(text);
        const data = parsed?.SPBluetoothDataType?.[0];
        if (!data)
            return;

        const controller = data.controller_properties ?? {};
        const adapter = root.defaultAdapter;
        adapter._updating = true;
        if (controller.controller_chipset)
            adapter.name = controller.controller_chipset;
        if (!root._hasBlueutil) {
            // Read-only fallback: system_profiler is the only source.
            adapter.enabled = controller.controller_state === "attrib_on";
            adapter.discoverable = controller.controller_discoverable === "attrib_on";
            adapter.state = adapter.enabled ? BluetoothAdapterState.Enabled : BluetoothAdapterState.Disabled;
        }
        adapter._updating = false;

        if (controller.controller_address && root.adapters.values.length === 0)
            root.adapters.values = [adapter];

        const records = {};
        for (const group of ["device_connected", "device_not_connected"]) {
            for (const entry of data[group] ?? []) {
                for (const name in entry) {
                    const info = entry[name] ?? {};
                    const address = root._normalize(info.device_address);
                    if (address === "")
                        continue;
                    const battery = root._battery(info);
                    records[address] = {
                        "address": address,
                        "name": name,
                        "icon": root._icon(info),
                        "connected": group === "device_connected",
                        // Without blueutil we cannot tell paired from merely
                        // known; system_profiler mostly lists paired devices.
                        "paired": true,
                        "battery": battery,
                        "batteryAvailable": battery > 0
                    };
                }
            }
        }

        root._fromProfiler = records;
        root._rebuild();
    }

    // BlueZ icon names, so Quickshell.iconPath() and end-4's
    // Icons.getBluetoothDeviceMaterialSymbol() resolve the same way as on Linux.
    function _icon(info: var): string {
        const kind = ((info.device_minorType ?? "") + " " + (info.device_majorType ?? "")).toLowerCase();
        if (kind.includes("headphone"))
            return "audio-headphones";
        if (kind.includes("headset") || kind.includes("hands-free"))
            return "audio-headset";
        if (kind.includes("speaker") || kind.includes("audio"))
            return "audio-card";
        if (kind.includes("keyboard"))
            return "input-keyboard";
        if (kind.includes("mouse"))
            return "input-mouse";
        if (kind.includes("trackpad") || kind.includes("tablet"))
            return "input-tablet";
        if (kind.includes("gamepad") || kind.includes("joystick"))
            return "input-gaming";
        if (kind.includes("phone"))
            return "phone";
        if (kind.includes("computer") || kind.includes("laptop"))
            return "computer";
        return "bluetooth";
    }

    // system_profiler reports "80%" strings. AirPods report per-bud levels instead
    // of a main level; use the lower of the two, which is what runs out first.
    function _battery(info: var): real {
        const read = key => {
            const raw = info[key];
            if (raw === undefined)
                return -1;
            const value = parseInt(String(raw).replace(/[^0-9]/g, ""), 10);
            return isNaN(value) ? -1 : value / 100;
        };
        const main = read("device_batteryLevelMain");
        if (main >= 0)
            return main;
        const left = read("device_batteryLevelLeft");
        const right = read("device_batteryLevelRight");
        if (left >= 0 && right >= 0)
            return Math.min(left, right);
        if (left >= 0)
            return left;
        if (right >= 0)
            return right;
        return 0;
    }

    // --- model maintenance --------------------------------------------------

    function _rebuild(): void {
        const merged = {};
        // Order matters: blueutil is authoritative for paired/connected, the
        // profiler for type and battery, inquiry only for extra nearby devices.
        for (const source of [root._fromInquiry, root._fromProfiler, root._fromBlueutil]) {
            for (const address in source) {
                merged[address] = Object.assign(merged[address] ?? {}, source[address]);
            }
        }
        // When blueutil is present it, not the profiler, decides connectedness.
        if (root._hasBlueutil) {
            for (const address in merged) {
                const known = root._fromBlueutil[address];
                merged[address].connected = known ? known.connected : false;
                merged[address].paired = known ? known.paired : false;
            }
        }

        const objects = root._objects;
        const values = [];

        for (const address in merged) {
            const record = merged[address];
            let device = objects[address];
            if (!device) {
                device = deviceComponent.createObject(root, {
                    "address": address,
                    "adapter": root.defaultAdapter
                });
                objects[address] = device;
            }

            device._updating = true;
            device.deviceName = record.name ?? address;
            if (device.name === "" || device.name === device.deviceName)
                device.name = device.deviceName;
            device.icon = record.icon ?? device.icon;
            device.paired = record.paired ?? false;
            device.bonded = device.paired;
            device.trusted = device.paired;
            device.connected = record.connected ?? false;
            // Hold an in-flight Connecting/Disconnecting only while it is still
            // plausible: the transition has not yet landed AND its deadline has not
            // passed. A blueutil --connect that silently fails must not leave the
            // device pinned to Connecting forever.
            const inTransit = device.state === BluetoothDeviceState.Connecting || device.state === BluetoothDeviceState.Disconnecting;
            const settling = inTransit && Date.now() < device._settleUntil && device.connected !== (device.state === BluetoothDeviceState.Connecting);
            if (!settling)
                device.state = device.connected ? BluetoothDeviceState.Connected : BluetoothDeviceState.Disconnected;
            if (record.battery !== undefined) {
                device.battery = record.battery;
                device.batteryAvailable = record.batteryAvailable ?? (record.battery > 0);
            }
            if (device.paired)
                device.pairing = false;
            device._updating = false;

            values.push(device);
        }

        for (const address in objects) {
            if (merged[address] === undefined) {
                objects[address].destroy();
                delete objects[address];
            }
        }

        values.sort((a, b) => a.address.localeCompare(b.address));
        root.devices.values = values;
    }

    // --- actions ------------------------------------------------------------

    // Queued so that two clicks in quick succession do not clobber each other's
    // Process command. A no-op when blueutil is not installed.
    function _exec(args: var): void {
        if (!root._hasBlueutil)
            return;
        root._queue = [...root._queue, args];
        root._pump();
    }

    function _pump(): void {
        if (execProc.running || root._queue.length === 0)
            return;
        const next = root._queue[0];
        root._queue = root._queue.slice(1);
        execProc.command = ["blueutil"].concat(next);
        execProc.running = true;
    }

    function _startDiscovery(): void {
        if (!root._hasBlueutil) {
            const adapter = root.defaultAdapter;
            adapter._updating = true;
            adapter.discovering = false;
            adapter._updating = false;
            return;
        }
        inquiryProc.running = true;
    }

    function _stopDiscovery(): void {
        inquiryProc.running = false;
    }

    function _finishDiscovery(): void {
        const adapter = root.defaultAdapter;
        adapter._updating = true;
        adapter.discovering = false;
        adapter._updating = false;
    }

    // --- processes ----------------------------------------------------------

    Component {
        id: deviceComponent

        BluetoothDevice {}
    }

    Process {
        id: pollProc

        running: true
        command: ["blueutil", "-p", "-d", "--paired", "--format", "json"]

        stdout: StdioCollector {
            onStreamFinished: root._applyPoll(text)
        }
    }

    Process {
        id: profilerProc

        running: true
        command: ["system_profiler", "SPBluetoothDataType", "-json"]

        stdout: StdioCollector {
            onStreamFinished: root._applyProfiler(text)
        }
    }

    Process {
        id: execProc

        // The shim's own write just landed: read it back now, not in 30 s.
        onExited: {
            root._pump();
            pollProc.running = true;
        }
    }

    Process {
        id: inquiryProc

        command: ["blueutil", "--inquiry", "8", "--format", "json"]

        stdout: StdioCollector {
            onStreamFinished: {
                const records = {};
                for (const entry of root._json(text) ?? []) {
                    const address = root._normalize(entry.address);
                    records[address] = {
                        "address": address,
                        "name": entry.name ?? address,
                        "paired": entry.paired ?? false,
                        "connected": entry.connected ?? false
                    };
                }
                root._fromInquiry = records;
                root._rebuild();
            }
        }

        onExited: root._finishDiscovery()
    }

    Timer {
        id: pollTimer

        interval: 30000
        running: true
        repeat: true
        onTriggered: pollProc.running = true
    }

    Timer {
        interval: 600000
        running: true
        repeat: true
        onTriggered: profilerProc.running = true
    }
}
