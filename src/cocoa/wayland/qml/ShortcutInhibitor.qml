// Quickshell.Wayland shim for macOS — ShortcutInhibitor
//
// NOTE ON THE NAME: upstream's QML element is `ShortcutInhibitor` (singular),
// from src/wayland/shortcuts_inhibit/inhibitor.hpp, and that is what the real
// configs import. `ShortcutsInhibitor.qml` is an alias file next to this one
// for anyone who guessed the plural.
//
// FULLY INERT. Upstream uses keyboard-shortcuts-inhibit-unstable-v1 to tell
// the compositor to stop swallowing keys. On macOS, system hotkeys are claimed
// by the WindowServer and can only be taken by a process holding an
// Accessibility grant and installing a CGEventTap — a C++/ObjC job, not
// something pure QML can do.
//
// `active` is permanently false, which is the correct answer: shortcuts are
// not being inhibited. A config that checks `active` before assuming it owns
// the keyboard will do the right thing. `cancelled` is never emitted.

import QtQuick

QtObject {
    id: root

    property bool enabled: false
    property var window: null
    readonly property bool active: false

    signal cancelled
}
