// Quickshell.Hyprland shim (macOS) — HyprlandFocusGrab
//
// REAL, via a native global event monitor.
//
// Upstream this drives hyprland_focus_grab_v1, which tells a shell surface that
// the user clicked somewhere else. end-4's GlobalFocusGrab service builds its
// whole dismissal model on it: the sidebars, the overview, the cheatsheet, the
// media controls and the wallpaper selector all register as "dismissable" and
// close when `cleared` arrives.
//
// macOS has no such protocol, but it does have global event monitors, and one of
// those is exactly the signal needed: a global monitor receives only events that
// went to a DIFFERENT application, so any click it reports is already outside our
// windows. See Quickshell.Cocoa.FocusGrab.
//
// DIFFERENCE FROM UPSTREAM: the grab is observational. Hyprland's real grab also
// routes input exclusively to the grabbing surface; a monitor cannot swallow the
// click, so the click both dismisses the panel and reaches whatever was clicked.
// In practice that is what a user expects from clicking away.

import QtQuick
import Quickshell.Cocoa as Cocoa

QtObject {
    id: root

    /// The windows whitelisted for input. Kept for API compatibility: the monitor
    /// reports only out-of-process clicks, so no hit testing against them is done.
    property var windows: []

    /// Whether the grab is held.
    property bool active: false

    /// Emitted when a click lands in another application.
    signal cleared

    property Cocoa.FocusGrab _monitor: Cocoa.FocusGrab {
        active: root.active

        onDismissed: {
            root.active = false;
            root.cleared();
        }
    }
}
