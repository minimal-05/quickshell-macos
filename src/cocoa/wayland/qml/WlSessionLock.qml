// Quickshell.Wayland shim for macOS — WlSessionLock
//
// FULLY INERT. Upstream implements ext-session-lock-v1, whose whole point is
// that the compositor keeps the session covered even if the locker crashes.
// macOS has no equivalent third-party API: the login window is owned by
// loginwindow/SecurityAgent and cannot be replaced or driven from a user
// process. Anything drawn from here would be a picture of a lock screen with
// the real session live behind it, so this shim refuses to pretend.
//
// `locked` is a plain read/write property. It stores what you write, and
// `secure` stays false forever, so a config that gates on `secure` will
// correctly conclude the session is not locked. `surface` accepts the
// component (upstream's default property) and never instantiates it.
//
// If you want a real macOS lock, run `pmset displaysleepnow` or the
// SACLockScreenImmediate keychain call from a Process instead.

import QtQuick

QtObject {
    id: root

    default property Component surface: null

    property bool locked: false
    readonly property bool secure: false
}
