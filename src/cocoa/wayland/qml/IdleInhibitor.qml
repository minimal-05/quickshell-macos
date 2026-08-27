// Quickshell.Wayland shim for macOS — IdleInhibitor
//
// REAL: `enabled` genuinely inhibits idle sleep. Upstream uses
// idle-inhibit-unstable-v1; here a `caffeinate -di` child process is held open
// for as long as enabled is true, which is the supported macOS mechanism
// (-d prevents display sleep, -i prevents idle system sleep). Verified with
// `pmset -g assertions`: PreventUserIdleDisplaySleep and
// PreventUserIdleSystemSleep both go to 1 while enabled.
//
// `-w <quickshell pid>` is passed so caffeinate exits on its own if quickshell
// dies without tearing the child down — without it a hard kill leaves the
// machine permanently awake, which was observed during testing.
//
// INERT: `window` is stored but ignored. On Wayland the compositor uses the
// associated surface to decide whether to honour the inhibitor; caffeinate is
// unconditional, so no window is needed and upstream's "must be set to a
// non-null value to enable" rule is deliberately NOT enforced here — enforcing
// it would make the inhibitor silently dead in configs that never set it.

import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: root

    property bool enabled: false
    property var window: null

    readonly property Process _caffeinate: Process {
        command: ["caffeinate", "-di", "-w", String(Quickshell.processId)]
        running: root.enabled
    }
}
