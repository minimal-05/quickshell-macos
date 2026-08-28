// Quickshell.Hyprland shim (macOS) — HyprlandWorkspace
//
// Backed by one entry of `yabai -m query --spaces`. A macOS Space maps onto a
// Hyprland workspace closely enough that the bar widgets in end-4 / caelestia
// work unchanged.
//
// REAL:  id (yabai space index), name, active (is-visible), focused
//        (has-focus), hasFullscreen (is-native-fullscreen), monitor,
//        toplevels, lastIpcObject (the raw yabai space JSON), activate().
// INERT: urgent — macOS has no per-window urgency hint reachable from a shell,
//        so it is always false.
//
// Objects are created and mutated by the Hyprland singleton; consumers should
// never construct one (upstream marks the type QML_UNCREATABLE, which pure QML
// cannot express, so an accidentally-constructed one is simply empty).

import QtQuick

QtObject {
    /// yabai space index. -1 until populated.
    property int id: -1

    /// yabai space label if one is set, otherwise the index as a string —
    /// matching Hyprland, where unnamed workspaces are named after their id.
    property string name: ""

    /// If this workspace is currently visible on its monitor.
    property bool active: false

    /// If this workspace is visible AND its monitor is focused.
    property bool focused: false

    /// INERT: always false. No urgency signal exists on macOS.
    property bool urgent: false

    /// If this space is in macOS native fullscreen.
    property bool hasFullscreen: false

    /// The raw yabai space object for this workspace.
    property var lastIpcObject: ({})

    /// The HyprlandMonitor this workspace lives on. May be null.
    property var monitor: null

    /// ObjectModel-alike: `toplevels.values` is an array of HyprlandToplevel.
    readonly property QtObject toplevels: QtObject {
        property var values: []
        readonly property int count: values.length
        function indexOf(object: var): int {
            return values.indexOf(object);
        }
    }

    /// Back-pointer to the Hyprland singleton, set at construction.
    property var ipc: null

    /// Activate the workspace. Equivalent to `Hyprland.dispatch("workspace <name>")`.
    function activate(): void {
        if (ipc)
            ipc.dispatch("workspace " + (name.length > 0 ? name : String(id)));
    }
}
