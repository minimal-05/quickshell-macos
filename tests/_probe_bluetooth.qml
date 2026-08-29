// Acceptance probe for the Bluetooth shim. Asserts the shape end-4's
// BluetoothStatus reads: defaultAdapter non-null, devices.values an array whose
// entries carry name/connected/paired/address.
//   bin/qs-test tests/_probe_bluetooth.qml -- bluetooth check == ok
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth

ShellRoot {
    // A QML singleton is instantiated on first reference, so touch it at load:
    // otherwise the first poll only starts with the first ipc call.
    Component.onCompleted: void Bluetooth.defaultAdapter

    IpcHandler {
        target: "bluetooth"

        function check(): string {
            const a = Bluetooth.defaultAdapter;
            if (!a)
                return "no-adapter";
            if (Bluetooth.adapters.values.length !== 1)
                return "adapters-empty";
            if (![BluetoothAdapterState.Enabled, BluetoothAdapterState.Disabled].includes(a.state))
                return "bad-state " + a.state;
            const devices = a.devices.values;
            if (!Array.isArray(devices) || devices !== Bluetooth.devices.values)
                return "bad-devices";
            for (const d of devices) {
                if (typeof d.name !== "string" || d.name.length === 0)
                    return "bad-name " + d.address;
                if (typeof d.connected !== "boolean" || typeof d.paired !== "boolean")
                    return "bad-flags " + d.address;
                if (!/^([0-9A-F]{2}:){5}[0-9A-F]{2}$/.test(d.address))
                    return "bad-address " + d.address;
                if (d.connected && d.state !== BluetoothDeviceState.Connected)
                    return "state-mismatch " + d.address;
            }
            return "ok";
        }

        function count(): string {
            return String(Bluetooth.devices.values.length);
        }

        function dump(): string {
            return JSON.stringify({
                "enabled": Bluetooth.defaultAdapter.enabled,
                "discoverable": Bluetooth.defaultAdapter.discoverable,
                "name": Bluetooth.defaultAdapter.name,
                "devices": Bluetooth.devices.values.map(d => ({
                    "address": d.address,
                    "name": d.name,
                    "connected": d.connected,
                    "paired": d.paired,
                    "icon": d.icon,
                    "battery": d.battery
                }))
            });
        }
    }
}
