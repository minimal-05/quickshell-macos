// Quickshell.Bluetooth -- macOS compatibility shim (pure QML, no C++).
//
// Mirrors qs::bluetooth::BluetoothAdapter (quickshell/src/bluetooth/adapter.hpp).
// Upstream this is QML_UNCREATABLE and backed by an org.bluez Adapter1 object.
// macOS has exactly one Bluetooth controller, so Bluetooth.qml creates exactly one
// of these (or none, if the machine has no Bluetooth hardware).
//
// REAL (via blueutil):
//   enabled       read `blueutil -p`, write `blueutil -p 0|1`  -- genuinely toggles
//                 the radio, no privilege prompt
//   state         derived from enabled, with Enabling/Disabling held until the next
//                 poll confirms the change
//   discovering   write true runs `blueutil --inquiry N`, which is a real scan and
//                 really does surface nearby unpaired devices into Bluetooth.devices;
//                 the flag clears itself when the scan finishes
//   name          the controller's chipset/address from system_profiler
//   devices       ObjectModel-shaped, exposing `.values`
//
// READ-ONLY IN PRACTICE:
//   discoverable  is read correctly from `blueutil -d`, and a write does issue
//                 `blueutil -d 0|1`, but macOS 12 and later refuse to turn
//                 discoverability on programmatically -- blueutil reports
//                 "Failed to switch bluetooth discoverable on in 10 seconds" and
//                 exits 75. Verified on this machine. The write is harmless and the
//                 property simply reverts on the next poll.
//
// INERT (declared, writable, but with no macOS counterpart):
//   pairable / pairableTimeout -- macOS is pairable only while System Settings >
//     Bluetooth is open, and that is neither queryable nor settable from a CLI.
//   discoverableTimeout        -- blueutil sets discoverability without a timeout.
//   dbusPath / adapterId       -- no D-Bus; synthesised so they stay stable and
//                                 non-empty for configs that key off them.

import QtQuick

QtObject {
    id: root

    property string name: "Bluetooth"
    property bool enabled: false
    property int state: BluetoothAdapterState.Disabled
    property bool discoverable: false
    property int discoverableTimeout: 0
    property bool discovering: false
    property bool pairable: false
    property int pairableTimeout: 0
    property string adapterId: "hci0"
    readonly property string dbusPath: "/org/bluez/" + root.adapterId

    // Same object as Bluetooth.devices -- macOS has a single controller, so every
    // device belongs to it.
    property QtObject devices: null

    property bool _updating: false

    onEnabledChanged: {
        if (root._updating)
            return;
        root.state = root.enabled ? BluetoothAdapterState.Enabling : BluetoothAdapterState.Disabling;
        Bluetooth._exec(["--power", root.enabled ? "1" : "0"]);
    }

    onDiscoverableChanged: {
        if (root._updating)
            return;
        Bluetooth._exec(["--discoverable", root.discoverable ? "1" : "0"]);
    }

    onDiscoveringChanged: {
        if (root._updating)
            return;
        if (root.discovering)
            Bluetooth._startDiscovery();
        else
            Bluetooth._stopDiscovery();
    }

    function startDiscovery(): void {
        root.discovering = true;
    }

    function stopDiscovery(): void {
        root.discovering = false;
    }
}
