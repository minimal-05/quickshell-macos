// Quickshell.Bluetooth -- macOS compatibility shim (pure QML, no C++).
//
// Mirrors qs::bluetooth::BluetoothDevice (quickshell/src/bluetooth/device.hpp).
// Upstream this is QML_UNCREATABLE and backed by an org.bluez Device1 object; here
// it is a plain component that Bluetooth.qml creates and keeps updated from
// `blueutil --paired/--connected/--inquiry --format json` plus
// `system_profiler SPBluetoothDataType -json`.
//
// REAL:
//   address, name, deviceName, connected (read AND write), state, paired, bonded,
//   icon, battery, batteryAvailable, adapter, dbusPath,
//   connect(), disconnect(), pair(), forget()
//
// INERT (declared and WRITABLE so consumer configs that toggle them do not throw,
//        but the write changes nothing on the system -- caelestia's BtDeviceInfo.qml
//        has switches bound to all three):
//   trusted     -- macOS auto-reconnects every paired device; there is no separate
//                  trust flag to read or set. Initialised to == paired.
//   blocked     -- no macOS equivalent of BlueZ's block list.
//   wakeAllowed -- not exposed by any macOS CLI.
//   pairing     -- set true by pair() but macOS drives pairing through its own
//                  system dialog, so there is no progress to observe.
//   Writing `name` (a BlueZ alias) has no macOS counterpart and is ignored.
//
// dbusPath is synthesised from the address. There is no D-Bus, but configs use it
// as a stable unique key, so an empty string would be worse than a synthetic one.

import QtQuick

QtObject {
    id: root

    property string address: ""
    // Upstream `name` is writable to set a BlueZ alias; there is no macOS alias
    // mechanism, so writes stick locally but change nothing on the system.
    property string name: ""
    property string deviceName: ""
    property string icon: "bluetooth"
    property int state: BluetoothDeviceState.Disconnected
    property bool paired: false
    property bool bonded: false
    property bool pairing: false
    property bool trusted: false
    property bool blocked: false
    property bool wakeAllowed: false
    property bool batteryAvailable: false
    // 0.0 - 1.0, matching upstream (system_profiler reports an integer percent).
    property real battery: 0
    // Upstream type is BluetoothAdapter*; QtObject avoids a load cycle between the
    // two component files. Property lookup through it is unaffected.
    property QtObject adapter: null
    readonly property string dbusPath: root.address === "" ? "" : "/org/bluez/hci0/dev_" + root.address.replace(/:/g, "_")

    // Writable, per upstream: "Setting this property is equivalent to calling
    // connect() and disconnect()." Bluetooth.qml sets _updating while it applies a
    // poll result so that reflecting reality is not mistaken for a user request.
    property bool connected: false
    property bool _updating: false
    // Deadline for an optimistic Connecting/Disconnecting state. blueutil's
    // --connect can fail silently (an iPhone, for instance, refuses classic BT
    // connections from a Mac), and without a deadline the device would sit in
    // Connecting forever. After this passes, _rebuild() syncs state to reality.
    property real _settleUntil: 0
    readonly property int _settleMs: 15000

    onConnectedChanged: {
        if (root._updating)
            return;
        if (root.connected)
            root.connect();
        else
            root.disconnect();
    }

    function connect(): void {
        if (root.address === "")
            return;
        root.state = BluetoothDeviceState.Connecting;
        root._settleUntil = Date.now() + root._settleMs;
        Bluetooth._exec(["--connect", root.address]);
    }

    function disconnect(): void {
        if (root.address === "")
            return;
        root.state = BluetoothDeviceState.Disconnecting;
        root._settleUntil = Date.now() + root._settleMs;
        Bluetooth._exec(["--disconnect", root.address]);
    }

    function pair(): void {
        if (root.address === "")
            return;
        root.pairing = true;
        Bluetooth._exec(["--pair", root.address]);
    }

    // blueutil marks --unpair EXPERIMENTAL, but it is the only unpair path
    // available outside the System Settings UI.
    function forget(): void {
        if (root.address === "")
            return;
        Bluetooth._exec(["--unpair", root.address]);
    }

    // macOS drives pairing through its own modal; there is nothing to cancel.
    function cancelPair(): void {
        root.pairing = false;
    }
}
