// Hover/leave probe for the macOS backend.
//
// Screenshot diffing cannot answer "did Qt see the pointer leave?" -- a video or
// a scrolling terminal behind the capture region changes every frame, which has
// already produced two confident but completely wrong conclusions. This asks the
// running QML directly over IPC instead, so a test is a string comparison.
//
// It reproduces the conditions that matter: a PanelWindow (borderless, never key,
// in an accessory process) with a hoverEnabled MouseArea, which is exactly the
// shape of end-4's bar and its StyledPopup hoverTarget.
//
//   quickshell -p tests/hoverprobe.qml &
//   quickshell ipc --pid <pid> call probe hover     -> "inside" | "outside"
//   quickshell ipc --pid <pid> call probe events    -> "enter=N leave=N last=..."

import Quickshell
import Quickshell.Io
import QtQuick

ShellRoot {
    id: root

    property int enterCount: 0
    property int leaveCount: 0
    property string lastEvent: "none"

    PanelWindow {
        anchors { top: true; left: true; right: true }
        implicitHeight: 40
        color: "#4400ff88"

        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            onEntered: { root.enterCount++; root.lastEvent = "enter"; }
            onExited: { root.leaveCount++; root.lastEvent = "leave"; }
        }
    }

    IpcHandler {
        target: "probe"

        function hover(): string {
            return area.containsMouse ? "inside" : "outside";
        }

        function events(): string {
            return `enter=${root.enterCount} leave=${root.leaveCount} last=${root.lastEvent}`;
        }

        function reset(): string {
            root.enterCount = 0;
            root.leaveCount = 0;
            root.lastEvent = "none";
            return "ok";
        }
    }
}
