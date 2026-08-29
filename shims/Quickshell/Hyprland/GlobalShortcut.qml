// Quickshell.Hyprland shim (macOS) — GlobalShortcut
//
// INERT with respect to hotkey registration.
//
// Upstream this speaks hyprland_global_shortcuts_v1, asking the compositor to
// bind a key for it. macOS has no such protocol, and pure QML cannot call
// Carbon's RegisterEventHotKey or -[NSEvent addGlobalMonitorForEventsMatching].
// So nothing here ever registers a key combination: onPressed / onReleased will
// not fire because a key was struck.
//
// BUT the object instantiates cleanly and keeps the whole upstream surface
// (appid / name / description / triggerDescription / pressed() / released()),
// which is the point — 27 files in end-4 declare one, and a missing type would
// stop all of them loading.
//
// WIRING IT UP FOR REAL (skhd route, skhd is already installed here):
// each instance publishes its own Quickshell IPC target, so a keybind can fire
// it from outside the process. Target name is `gs_<appid>_<name>` with every
// character outside [A-Za-z0-9_] replaced by "_". For
//     GlobalShortcut { name: "panelFamilyCycle" }   // appid defaults "quickshell"
// the target is `gs_quickshell_panelFamilyCycle`, and ~/.skhdrc gets:
//     cmd - a : qs ipc call gs_quickshell_panelFamilyCycle press
// `press` emits pressed() then released(); `down` and `up` emit them
// separately, for shortcuts that care about hold-to-show behaviour.
// Run `qs ipc show` against a live config to list every registered target.
//
// Hyprland.dispatch('hl.dsp.global("appid:name")') reaches the instance in
// this process directly: each one registers itself in Hyprland.shortcuts
// under "appid:name" while it exists.

import QtQuick
import Quickshell.Io

QtObject {
    id: root

    /// Application id the shortcut is registered under.
    property string appid: "quickshell"

    /// Name of the shortcut. Unique per appid.
    property string name: ""

    /// Human readable description.
    property string description: ""

    /// Human readable description of the intended keybind.
    property string triggerDescription: ""

    /// Emitted when the shortcut is triggered.
    /// On macOS this only ever comes from the IPC target described above.
    signal pressed

    /// Emitted when the shortcut's key is released.
    signal released

    /// The IPC target this instance answers on. Empty while `name` is unset.
    readonly property string ipcTarget: root.name.length === 0 ? "" : ("gs_" + root.appid + "_" + root.name).replace(/[^A-Za-z0-9_]/g, "_")

    readonly property string _key: root.appid + ":" + root.name

    function _register(): void {
        if (root.name.length === 0)
            return;
        const all = Hyprland.shortcuts;
        all[root._key] = root;
        Hyprland.shortcuts = all;
    }

    Component.onCompleted: root._register()
    on_KeyChanged: root._register()
    Component.onDestruction: {
        const all = Hyprland.shortcuts;
        if (all[root._key] === root) {
            delete all[root._key];
            Hyprland.shortcuts = all;
        }
    }

    readonly property IpcHandler _ipc: IpcHandler {
        target: root.ipcTarget
        enabled: root.ipcTarget.length > 0

        function press(): string {
            root.pressed();
            root.released();
            return "ok";
        }

        function down(): string {
            root.pressed();
            return "ok";
        }

        function up(): string {
            root.released();
            return "ok";
        }
    }
}
