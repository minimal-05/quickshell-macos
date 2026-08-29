// Swapchain-release probe for the macOS backend (PF-06).
//
// A hidden panel used to keep its Metal drawables: two hidden full-height
// panels held 113 MB of IOSurface between them. This root opens and closes a
// full-height panel over IPC so tests/swapchain.sh can read `vmmap --summary`
// on the process in each state, and counts frameSwapped so a re-shown panel
// can be proven to render again.
//
//   qs-test tests/swapchain.qml --shell
//   quickshell -p tests/swapchain.qml ipc call probe open      -> "ok"
//   quickshell -p tests/swapchain.qml ipc call probe close     -> "ok"
//   quickshell -p tests/swapchain.qml ipc call probe frames    -> "N"
//   quickshell -p tests/swapchain.qml ipc call probe state     -> "visible=.. backing=.."

import Quickshell
import Quickshell.Io
import QtQuick

ShellRoot {
    id: root

    property bool open: false
    property int frames: 0

    PanelWindow {
        id: panel
        visible: root.open
        anchors { top: true; bottom: true; left: true }
        implicitWidth: 600
        color: "#2200ff88"

        Rectangle {
            id: content
            anchors.fill: parent
            anchors.margins: 20
            color: "#4400ffff"
            radius: 24
            Text { anchors.centerIn: parent; text: "swapchain probe"; font.pixelSize: 40 }
        }

        Connections {
            target: content.Window.window
            function onFrameSwapped() { root.frames++; }
        }
    }

    // The animate: false opt-out: this one must be gone the moment it is told
    // to hide, not 270 ms later.
    property bool instantOpen: false

    PanelWindow {
        id: instant
        visible: root.instantOpen
        animate: false
        anchors { top: true; right: true }
        implicitWidth: 200
        implicitHeight: 100
        color: "#44ff0088"
    }

    IpcHandler {
        target: "probe"

        function open(): string { root.open = true; return "ok"; }
        function close(): string { root.open = false; return "ok"; }
        function frames(): string { return `${root.frames}`; }
        function state(): string {
            return `visible=${panel.visible} backing=${panel.backingWindowVisible}`;
        }

        function instantToggle(open: bool): string {
            root.instantOpen = open;
            return `backing=${instant.backingWindowVisible}`;
        }
    }
}
