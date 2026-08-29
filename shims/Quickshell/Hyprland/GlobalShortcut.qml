// Quickshell.Hyprland shim (macOS) — GlobalShortcut
//
// REAL, via Carbon hot keys (Quickshell.Cocoa.Hotkeys).
//
// Upstream this speaks hyprland_global_shortcuts_v1: the compositor owns the
// key, the shell only learns its name was triggered. macOS has no such protocol,
// so the Hotkeys singleton registers the chord itself with RegisterEventHotKey
// and reports presses and releases per `appid:name`. Which chord a name gets is
// the table in src/cocoa/shortcuts.json, overlaid by
// ~/.config/quickshell-macos/shortcuts.json; a name with no chord there is
// declared but never fires from the keyboard, same as a Hyprland config with no
// `bind = ..., global, quickshell:name` line.
//
// DIFFERENCES FROM UPSTREAM: a bare modifier (SUPER hold for workspaceNumber)
// cannot be a hot key, so those names stay IPC-only; a chord skhd also binds is
// left to skhd (see Hotkeys). As upstream, appid and name are read once, when
// the object completes.
//
// IPC ROUTE, kept for scripts and for the names that have no chord: each
// instance answers on `gs_<appid>_<name>` (every character outside
// [A-Za-z0-9_] replaced by "_"), so
//     qs ipc call gs_quickshell_panelFamilyCycle press
// emits pressed() then released(); `down` and `up` emit them separately.

import QtQuick
import Quickshell.Io
import Quickshell.Cocoa as Cocoa

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
    signal pressed

    /// Emitted when the shortcut's key is released.
    signal released

    /// The IPC target this instance answers on. Empty while `name` is unset.
    readonly property string ipcTarget: root.name.length === 0 ? "" : ("gs_" + root.appid + "_" + root.name).replace(/[^A-Za-z0-9_]/g, "_")

    // What was registered, so a later change to appid/name (unsupported
    // upstream too) cannot leave a registration behind.
    property var _bound: null

    Component.onCompleted: {
        if (root.name.length === 0)
            return;
        root._bound = [root.appid, root.name];
        Cocoa.Hotkeys.bind(root.appid, root.name);
    }

    Component.onDestruction: {
        if (root._bound !== null)
            Cocoa.Hotkeys.unbind(root._bound[0], root._bound[1]);
    }

    readonly property Connections _keys: Connections {
        target: Cocoa.Hotkeys

        function onPressed(appid: string, name: string) {
            if (root._bound !== null && appid === root._bound[0] && name === root._bound[1])
                root.pressed();
        }

        function onReleased(appid: string, name: string) {
            if (root._bound !== null && appid === root._bound[0] && name === root._bound[1])
                root.released();
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
