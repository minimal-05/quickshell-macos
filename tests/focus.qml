// Activation hand-back probe for the macOS backend (P1-03).
//
// A focusable panel takes the keyboard when it shows and gives it back when it
// hides. Neither is observable from a screenshot; both are from the outside
// through `lsappinfo front`, and from the inside through Window.active. This
// root exposes show/hide over IPC so tests/focus.sh can drive one cycle and
// time the hand-back.
//
//   qs-test tests/focus.qml --shell
//   quickshell -p tests/focus.qml ipc call probe open     -> "ok"
//   quickshell -p tests/focus.qml ipc call probe active   -> "true" | "false"
//   quickshell -p tests/focus.qml ipc call probe close    -> "ok"
//
// Not show/hide: `ipc call <target> show` is swallowed by the CLI's own
// `ipc show` and lists the target instead of calling it.

import Quickshell
import Quickshell.Io
import QtQuick

ShellRoot {
    id: root

    property bool open: false

    PanelWindow {
        id: panel
        visible: root.open
        focusable: true
        anchors { top: true; left: true; right: true }
        implicitHeight: 60
        color: "#4400ff88"

        TextInput {
            id: input
            anchors.fill: parent
            focus: true
            text: "focus probe"
        }
    }

    IpcHandler {
        target: "probe"

        function open(): string { root.open = true; return "ok"; }
        function close(): string { root.open = false; return "ok"; }

        // Window.active is the QQuickWindow's own view of being the key window
        // of the active application, i.e. whether keys would reach `input`.
        function active(): string {
            return input.Window.active ? "true" : "false";
        }
    }
}
