// Quickshell.Wayland shim for macOS — WlSessionLock
//
// REAL, with a caveat. Upstream implements ext-session-lock-v1, whose whole
// point is that the compositor keeps the session covered even if the locker
// crashes. macOS has no compositor-level equivalent -- the login window is
// owned by loginwindow/SecurityAgent and cannot be replaced -- so this is a
// best-effort overlay instead: one focusable, always-on-top PanelWindow per
// screen, hosting `surface`. If this process dies while locked, the overlay
// dies with it and the desktop underneath is exposed -- there is no
// compositor backstop. `secure` stays false for exactly that reason: a
// config gating on it should correctly conclude this is not a crash-proof
// lock.
//
// `locked` toggles the overlay on and off. `surface` is upstream's default
// property: a Component whose root is (or wraps) WlSessionLockSurface,
// instantiated once per Quickshell.screens entry, same as a real output.

import QtQuick
import Quickshell
import Quickshell.Wayland

Scope {
    id: root

    default property Component surface: null

    property bool locked: false
    readonly property bool secure: false

    Loader {
        active: root.locked

        sourceComponent: Variants {
            model: Quickshell.screens

            delegate: PanelWindow {
                id: lockPanel

                required property var modelData
                screen: modelData
                focusable: true
                color: "transparent"
                exclusionMode: ExclusionMode.Ignore
                WlrLayershell.namespace: "quickshell:lock"
                WlrLayershell.layer: WlrLayer.Overlay

                anchors {
                    top: true
                    bottom: true
                    left: true
                    right: true
                }

                Loader {
                    anchors.fill: parent
                    active: true
                    sourceComponent: root.surface
                    onLoaded: if (item) item.screen = lockPanel.screen
                }
            }
        }
    }
}
