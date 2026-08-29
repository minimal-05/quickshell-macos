import QtQuick

// Quickshell.Services.Pipewire.PwNodePeakMonitor - macOS compatibility shim.
//
// INERT STUB. Upstream this captures a node's audio and reports per-channel
// peak levels for VU meters. `node` and `enabled` are real read/write
// properties so bindings work; `peaks` is empty and `peak` is 0 forever, so a
// meter draws silence rather than throwing.
// ponytail: a CoreAudio IOProc on the device (or a process tap, macOS 14.2+)
// would supply real peaks. Nothing in the shell config reads this yet, so it
// is not wired.
QtObject {
    id: root

    property PwNode node: null
    property bool enabled: true

    readonly property var peaks: []
    readonly property real peak: 0
    readonly property var channels: []
}
