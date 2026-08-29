// Quickshell.Hyprland shim (macOS) — HyprlandToplevel
//
// Backed by one entry of `yabai -m query --windows`.
//
// REAL:  address (yabai window id rendered as lowercase hex, matching
//        upstream's QString::number(addr, 16) — consumers prefix "0x"
//        themselves), title, activated (has-focus), workspace, monitor,
//        lastIpcObject (the raw yabai window JSON, which carries app, frame,
//        pid, is-floating, is-minimized ... — everything HyprlandData-style
//        code reads out of `hyprctl clients`), wayland (the Quickshell.Wayland
//        Toplevel for the same yabai window, so `wayland?.fullscreen` works
//        the way Background/ScreenCorners use it).
// INERT: urgent  — no urgency hint on macOS, always false.
//        handle  — self, so `t.handle.address` still resolves.
//
// NOT PROVIDED: the attached form. Upstream registers this type as
// QML_ATTACHED so configs write `someWaylandToplevel.HyprlandToplevel.address`.
// Pure QML cannot declare attached properties, so that expression yields
// undefined. Every consumer site found in end-4 uses `?.` on it, so it degrades
// to an undefined address rather than a hard error.

import QtQuick
import Quickshell.Wayland

QtObject {
    id: root

    /// Lowercase hex of the yabai window id, with no "0x" prefix.
    property string address: ""

    /// Self, so upstream's `toplevel.handle` chain resolves.
    readonly property var handle: root

    /// The Quickshell.Wayland Toplevel backed by the same yabai window, or
    /// null until ToplevelManager has seen it. Both shims key on the window id.
    readonly property var wayland: ToplevelManager.toplevels.values.find(t => t.wid === parseInt(root.address, 16)) ?? null

    property string title: ""

    /// If this window currently has focus.
    property bool activated: false

    /// INERT: always false.
    property bool urgent: false

    /// The raw yabai window object.
    property var lastIpcObject: ({})

    /// The HyprlandWorkspace this window is on. May be null.
    property var workspace: null

    /// The HyprlandMonitor this window is on. May be null.
    property var monitor: null

    /// Convenience mirror of the yabai `app` field. Not upstream API, but
    /// harmless and often what a config actually wants from lastIpcObject.
    readonly property string appName: root.lastIpcObject && root.lastIpcObject.app ? root.lastIpcObject.app : ""
}
