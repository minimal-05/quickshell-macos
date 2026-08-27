// Quickshell.Wayland shim for macOS — IdleMonitor
//
// REAL: `isIdle` is driven by the HID idle counter, which is the same thing
// the OS itself uses to decide the user is away:
//     ioreg -c IOHIDSystem -d 4 -k HIDIdleTime   (nanoseconds since last input)
// Polled once a second while `enabled`, compared against `timeout` (seconds,
// same unit as upstream). Defaults match upstream: enabled = true, timeout = 0
// (idle reported immediately), respectInhibitors = true.
//
// INERT: `respectInhibitors` is stored but has no effect. macOS has no way to
// ask "is anything currently asserting NoIdleSleepAssertion on my behalf" that
// maps onto a per-compositor inhibitor list, and an IdleInhibitor started by
// this same shell does not stop the HID counter from advancing. Configs that
// set it false get the same behaviour as true.
//
// The poll is 1s, so isIdle can lag a sub-second timeout by up to a second.

import QtQuick
import Quickshell.Io

QtObject {
    id: root

    property bool enabled: true
    property real timeout: 0
    property bool respectInhibitors: true
    readonly property bool isIdle: enabled && _idleSeconds >= timeout

    // Shim-only. Not part of the upstream API.
    property real _idleSeconds: 0

    readonly property Process _query: Process {
        id: query

        command: ["sh", "-c", "ioreg -c IOHIDSystem -d 4 -k HIDIdleTime | awk '/HIDIdleTime/ {print $NF; exit}'"]

        stdout: StdioCollector {
            onStreamFinished: {
                const ns = parseFloat(text.trim());
                if (!isNaN(ns))
                    root._idleSeconds = ns / 1000000000;
            }
        }
    }

    readonly property Timer _poll: Timer {
        interval: 1000
        running: root.enabled
        repeat: true
        triggeredOnStart: true
        onTriggered: query.running = true
    }
}
