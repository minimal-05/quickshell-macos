// Quickshell.Wayland shim for macOS — Toplevel
//
// A window belonging to another application. Upstream this wraps a
// zwlr_foreign_toplevel_handle_v1; here it wraps one entry of
// `yabai -m query --windows`. Instances are owned and refreshed by
// ToplevelManager — never construct one yourself (upstream marks the type
// QML_UNCREATABLE for the same reason; pure QML cannot enforce that).
//
// REAL (kept live by ToplevelManager's 1s poll):
//   appId      <- yabai `app`   (see gap note: this is the macOS app *name*,
//                                e.g. "kitty"/"Safari", not a reverse-DNS id)
//   title      <- yabai `title`
//   activated  <- yabai `has-focus`
//   minimized  <- yabai `is-minimized`
//   fullscreen <- yabai `is-native-fullscreen`
//   maximized  <- yabai `has-fullscreen-zoom` (zoom-to-fullscreen; the closest
//                 macOS analogue of a maximized window)
//   screens    <- Quickshell.screens entry for yabai `display`
//   activate() -> yabai -m window --focus <id>
//   close()    -> yabai -m window <id> --close
//   closed()   emitted by the manager when the window disappears
//
// INERT:
//   parent           always null — macOS/yabai does not report sheet or dialog
//                    parentage in the window query.
//   fullscreenOn()   no-op; macOS native fullscreen cannot be targeted at a
//                    specific display from the CLI.
//   setRectangle()/unsetRectangle()  no-op; these are minimize-animation hints
//                    for a Wayland compositor and have no macOS equivalent.
//   Writing maximized/minimized/fullscreen is accepted and stored but does NOT
//   drive the window — the next poll overwrites it. Deliberate: the poll would
//   otherwise fight the write and loop.

import QtQuick
import Quickshell.Io

QtObject {
    id: root

    // Shim-only handle. Not part of the upstream API.
    property int wid: -1

    property string appId: ""
    property string title: ""
    property bool activated: false
    property var parent: null
    property var screens: []
    property bool maximized: false
    property bool minimized: false
    property bool fullscreen: false

    signal closed

    function activate(): void {
        if (root.wid < 0)
            return;
        dispatch.exec(["yabai", "-m", "window", "--focus", String(root.wid)]);
    }

    function close(): void {
        if (root.wid < 0)
            return;
        dispatch.exec(["yabai", "-m", "window", String(root.wid), "--close"]);
    }

    function fullscreenOn(screen): void {}
    function setRectangle(window, rect): void {}
    function unsetRectangle(): void {}

    // QtObject has no default property, so the Process lives on a named one.
    readonly property Process _dispatch: Process {
        id: dispatch
    }
}
