// Input-mask probe for the macOS backend (P1-01).
//
// PanelWindow.mask is a hit-test region: the pointer is "in" the panel only
// inside the region, and the panel still paints all of itself. This root has
// a full-width panel with a small mask and reports hover state and geometry
// over IPC; tests/mask.sh moves the pointer and reads the native window's
// bounds from the window server.
//
//   quickshell -p tests/mask.qml ipc call probe hover        -> "inside" | "outside"
//   quickshell -p tests/mask.qml ipc call probe geometry     -> "x,y,w,h" of the panel (global points)
//   quickshell -p tests/mask.qml ipc call probe maskRect     -> "x,y,w,h" of the mask, global
//   quickshell -p tests/mask.qml ipc call probe setMask <full|small|empty>

import Quickshell
import Quickshell.Io
import QtQuick

ShellRoot {
    id: root

    property string mode: "small"
    property int enterCount: 0
    property int leaveCount: 0

    PanelWindow {
        id: panel
        anchors { top: true; left: true; right: true }
        implicitHeight: 200
        color: "#3300ff88"

        // "full": no mask (whole window). "small": a rect. "empty": a set but
        // empty region, which upstream treats as "takes no input at all".
        mask: root.mode === "full" ? null : region
        Region {
            id: region
            x: 100; y: 50
            width: root.mode === "empty" ? 0 : 200
            height: root.mode === "empty" ? 0 : 100
        }

        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            onEntered: root.enterCount++
            onExited: root.leaveCount++
        }
    }

    IpcHandler {
        target: "probe"

        function hover(): string { return area.containsMouse ? "inside" : "outside"; }
        function events(): string { return `enter=${root.enterCount} leave=${root.leaveCount}`; }

        function geometry(): string {
            const p = panel.contentItem.mapToGlobal(0, 0);
            return `${p.x},${p.y},${panel.width},${panel.height}`;
        }

        function maskRect(): string {
            const p = panel.contentItem.mapToGlobal(region.x, region.y);
            return `${p.x},${p.y},${region.width},${region.height}`;
        }

        function setMask(mode: string): string { root.mode = mode; return root.mode; }
    }
}
