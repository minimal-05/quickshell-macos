// Quickshell.Hyprland shim (macOS) — HyprlandMonitor
//
// Backed by one entry of `yabai -m query --displays`, with `name` deliberately
// taken from the matching Quickshell.screens entry rather than from yabai.
// Consumer configs constantly do
//     Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name)
// so the names MUST agree; on this machine that means "Built-in Retina Display"
// rather than a Linux connector name like "eDP-1".
//
// REAL:  id (yabai display index), name, x, y, width, height, scale,
//        activeWorkspace, focused, lastIpcObject (raw yabai display JSON).
// INERT: description — macOS exposes no EDID-ish description through yabai, so
//        it mirrors `name`.

import QtQuick

QtObject {
    /// yabai display index. -1 until populated.
    property int id: -1

    /// The Quickshell screen name for this display, so that `===` comparisons
    /// against `Quickshell.screens[].name` succeed.
    property string name: ""

    /// INERT: mirrors `name`; no separate description is available.
    property string description: ""

    property int x: 0
    property int y: 0
    property int width: 0
    property int height: 0
    property real scale: 1.0

    /// The raw yabai display object.
    property var lastIpcObject: ({})

    /// The currently visible workspace on this monitor. May be null.
    property var activeWorkspace: null

    /// If this monitor currently has focus.
    property bool focused: false
}
