// Probe for the Quickshell.Hyprland / Quickshell.Wayland shims on yabai
// signals: workspaces and toplevels populate, focus changes arrive through
// the signal files, and nothing periodic runs in between.
//
//   bin/qs-test tests/_probe_hyprland.qml -- hyprland check          == ok
//   bin/qs-test tests/_probe_hyprland.qml -- hyprland focused        the focused Space index
//   bin/qs-test tests/_probe_hyprland.qml -- hyprland focusedAt      ms timestamp of the last focusedWorkspace change
//   bin/qs-test tests/_probe_hyprland.qml -- hyprland queries        "<spaces/displays> <windows>" query counts
//   bin/qs-test tests/_probe_hyprland.qml -- hyprland events         synthesised rawEvent names seen
//   bin/qs-test tests/_probe_hyprland.qml -- hyprland dispatch <cmd> run one dispatcher string
//   bin/qs-test tests/_probe_hyprland.qml -- hyprland wayland        address of the first toplevel whose .wayland resolves
//   bin/qs-test tests/_probe_hyprland.qml -- hyprland global         fire hl.dsp.global("quickshell:qstest") and report

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

ShellRoot {
    id: root

    property real focusedAt: 0
    property int shortcutPresses: 0
    property var events: []

    GlobalShortcut {
        name: "qstest"
        onPressed: root.shortcutPresses++
    }

    Connections {
        target: Hyprland
        function onFocusedWorkspaceChanged() { root.focusedAt = Date.now(); }
        function onRawEvent(event) {
            if (root.events.indexOf(event.name) === -1)
                root.events = root.events.concat([event.name]);
        }
    }

    IpcHandler {
        target: "hyprland"

        function check(): string {
            const ws = Hyprland.workspaces.values.length;
            const tl = Hyprland.toplevels.values.length;
            const wl = ToplevelManager.toplevels.values.length;
            const mon = Hyprland.monitors.values.length;
            if (ws === 0) return "no-workspaces";
            if (mon === 0) return "no-monitors";
            if (!Hyprland.focusedWorkspace) return "no-focused-workspace";
            if (tl !== wl) return `toplevel-count-mismatch ${tl} vs ${wl}`;
            return "ok";
        }

        function focused(): string {
            return String(Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1);
        }

        function focusedAt(): string {
            return String(root.focusedAt);
        }

        function queries(): string {
            return Hyprland._queries + " " + ToplevelManager._queries;
        }

        function events(): string {
            return root.events.join(",");
        }

        function dispatch(cmd: string): string {
            Hyprland.dispatch(cmd);
            return "sent";
        }

        function wayland(): string {
            const hit = Hyprland.toplevels.values.find(t => t.wayland !== null);
            return hit ? ("0x" + hit.address + " fullscreen=" + hit.wayland.fullscreen) : "none";
        }

        function global(): string {
            const before = root.shortcutPresses;
            Hyprland.dispatch('hl.dsp.global("quickshell:qstest")');
            return root.shortcutPresses > before ? "pressed" : "not-pressed";
        }

        function occupied(): string {
            return Hyprland.workspaces.values.map(w => w.id + ":" + w.lastIpcObject.windows.length + (w.active ? "v" : "")).join(",");
        }
    }
}
