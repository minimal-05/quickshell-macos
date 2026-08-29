// Acceptance probe for GlobalShortcut via Carbon hot keys (P0-01). Driven by
// tests/hotkeys.sh, which points QS_SHORTCUTS at a private chord table binding
// qstest/qsheld/qsskhd/qsmod to F17-F19 chords and a bare modifier, and posts
// the chords with CGEvent. By hand:
//   bin/qs-test tests/_probe_hotkeys.qml --shell         then press the chord
//   bin/quickshell -p tests/_probe_hotkeys.qml ipc call hotkeys events
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Cocoa as Cocoa

ShellRoot {
    id: root
    property int pressedCount: 0
    property int releasedCount: 0
    property list<string> events: []

    function note(e: string) {
        root.events = root.events.concat([e]);
        console.log("hotkey", e);
    }

    GlobalShortcut {
        name: "qstest"
        description: "Probe: tapped by tests/hotkeys.sh"
        onPressed: { root.pressedCount++; root.note("qstest:down"); }
        onReleased: { root.releasedCount++; root.note("qstest:up"); }
    }

    // Same name declared twice, as end-4 does for barToggle etc: both must
    // fire from one registration.
    GlobalShortcut {
        name: "qstest"
        onPressed: root.note("qstest2:down")
    }

    GlobalShortcut {
        name: "qsheld"
        description: "Probe: held, to see press and release arrive apart"
        onPressed: root.note("qsheld:down")
        onReleased: root.note("qsheld:up")
    }

    GlobalShortcut {
        name: "qsskhd"
        description: "Probe: chord the private skhdrc also binds; must stay unbound"
        onPressed: root.note("qsskhd:down")
    }

    GlobalShortcut {
        name: "qsmod"
        description: "Probe: bare modifier; must stay unbound"
        onPressed: root.note("qsmod:down")
    }

    IpcHandler {
        target: "hotkeys"
        function pressed(): string { return String(root.pressedCount); }
        function released(): string { return String(root.releasedCount); }
        function events(): string { return root.events.join(" "); }
        function chord(name: string): string { return Cocoa.Hotkeys.chord("quickshell", name); }
        function bindings(): string { return JSON.stringify(Cocoa.Hotkeys.bindings); }
        function reset(): string { root.pressedCount = 0; root.releasedCount = 0; root.events = []; return "ok"; }
    }
}
