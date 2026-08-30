// Exclusive-zone probe for the macOS backend (P1-02).
//
// A panel with exclusiveZone: 40 on the top edge, moved to the bottom over
// IPC. The backend sums the zones of visible panels per edge into
// Quickshell.Cocoa.Reservation and, with applyToYabai on, writes yabai's
// external_bar itself; tests/reservation.sh reads yabai back after each
// change and restores the user's values afterwards.
//
//   quickshell -p tests/reservation.qml ipc call probe zones          -> "top,bottom,left,right"
//   quickshell -p tests/reservation.qml ipc call probe edge bottom    -> "bottom"
//   quickshell -p tests/reservation.qml ipc call probe shown false    -> "false"

import Quickshell
import Quickshell.Cocoa
import Quickshell.Io
import QtQuick

ShellRoot {
    id: root

    property string edge: "top"
    property bool shown: true

    PanelWindow {
        visible: root.shown
        anchors { top: root.edge === "top"; bottom: root.edge === "bottom"; left: true; right: true }
        implicitHeight: 64
        exclusiveZone: 40
        color: "#3300ff88"
    }

    Component.onCompleted: Reservation.applyToYabai = true

    IpcHandler {
        target: "probe"

        function zones(): string {
            return `${Reservation.top},${Reservation.bottom},${Reservation.left},${Reservation.right}`;
        }
        function edge(which: string): string { root.edge = which; return root.edge; }
        function shown(on: bool): string { root.shown = on; return `${root.shown}`; }
    }
}
