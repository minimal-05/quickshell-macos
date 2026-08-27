// Quickshell.Wayland shim for macOS — ScreencopyView
//
// FULLY INERT. Upstream streams frames over wlr-screencopy /
// ext-image-copy-capture / hyprland-toplevel-export. macOS screen capture goes
// through ScreenCaptureKit, which needs a C++/ObjC backend and a TCC
// screen-recording grant — neither is reachable from pure QML. Shelling out to
// `screencapture` would give a one-shot PNG on disk, not a live surface, and
// would fire a permission prompt per frame, so nothing is wired up.
//
// The type exists as an Item so it lays out and sizes like the real one and
// consumer bindings resolve. `hasContent` stays false, which is exactly the
// flag upstream tells configs to gate display on — a config that respects it
// will show its placeholder instead of an empty rectangle.

import QtQuick

Item {
    id: root

    property var captureSource: null
    property bool paintCursor: false
    property bool live: false
    readonly property bool hasContent: false
    readonly property size sourceSize: Qt.size(0, 0)
    property size constraintSize: Qt.size(0, 0)

    signal stopped

    function captureFrame(): void {}
}
