// Quickshell.Wayland shim for macOS — ScreencopyView
//
// Upstream streams frames over wlr-screencopy / ext-image-copy-capture /
// hyprland-toplevel-export. macOS has none of those, but it does have
// `screencapture -l<CGWindowID>`, and a yabai window id IS a CGWindowID — so a
// frame per window is one subprocess away. bin/qs-window-thumbs already owns
// that command, the downscale and the atomic write, so this asks it for a
// single window and binds the path it prints.
//
// REAL:
//   captureSource   a Quickshell.Wayland.Toplevel (its shim-only `wid`).
//   hasContent      true once a frame has actually loaded, so a consumer that
//                   gates on it keeps its placeholder until then — and keeps it
//                   for good for a source that cannot be captured.
//   sourceSize      the captured image's own pixel size.
//   constraintSize  same contract as upstream: a nonzero width and/or height
//                   constrains implicit size, keeping the image's aspect ratio.
//   captureFrame()  grab one frame now.
//
// GAPS:
//   A still, not a live feed. `live` re-grabs on a timer while the view is on
//   screen instead of streaming — one screencapture per window per tick is too
//   expensive to run faster, and a hover preview does not need faster.
//
//   ShellScreen sources are not handled, only toplevels. hasContent stays false
//   for one, which is what consumers saw when this whole shim was inert.
//
//   paintCursor is inert: `screencapture -l` captures a window's own buffer and
//   has no cursor to paint into it.
//
//   A minimized window has no buffer to capture, so it is skipped rather than
//   left showing a stale frame.

import QtQuick
import Quickshell.Io

Item {
    id: root

    property var captureSource: null
    property bool paintCursor: false
    property bool live: false
    property size constraintSize: Qt.size(0, 0)

    readonly property bool hasContent: image.status === Image.Ready
    readonly property size sourceSize: image.sourceSize

    signal stopped

    // Shim-only. Not part of the upstream API.
    readonly property int windowId: root.captureSource?.wid ?? -1
    readonly property bool capturable: root.windowId >= 0 && !(root.captureSource?.minimized ?? false)

    // Upstream's binding, from src/wayland/screencopy/view.cpp.
    readonly property size fittedSize: {
        const src = root.sourceSize;
        const constraint = root.constraintSize;

        if (!root.hasContent || src.width <= 0 || src.height <= 0)
            return Qt.size(0, 0);

        if (constraint.width > 0 && constraint.height > 0) {
            const scale = Math.min(constraint.width / src.width, constraint.height / src.height);
            return Qt.size(src.width * scale, src.height * scale);
        }
        if (constraint.width > 0)
            return Qt.size(constraint.width, src.height * (constraint.width / src.width));
        if (constraint.height > 0)
            return Qt.size(src.width * (constraint.height / src.height), constraint.height);

        return src;
    }

    implicitWidth: root.fittedSize.width
    implicitHeight: root.fittedSize.height

    function captureFrame(): void {
        if (!root.capturable || capture.running)
            return;
        capture.running = true;
    }

    onWindowIdChanged: {
        image.source = "";
        root.captureFrame();
    }

    onVisibleChanged: if (root.visible) root.captureFrame()

    Component.onCompleted: if (root.visible) root.captureFrame()

    Image {
        id: image
        anchors.fill: parent
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true

        // qs-window-thumbs writes the same path every time, so a cached frame
        // would be the only one ever shown.
        cache: false
    }

    Timer {
        running: root.live && root.visible && root.capturable
        interval: 2000
        repeat: true
        onTriggered: root.captureFrame()
    }

    Process {
        id: capture
        command: ["qs-window-thumbs", String(root.windowId)]

        stdout: StdioCollector {
            onStreamFinished: {
                const path = text.trim();
                if (path === "")
                    return;

                // Clearing first is what forces the re-read; `cache: false`
                // alone does not, because the URL has not changed.
                image.source = "";
                image.source = "file://" + path;
            }
        }
    }
}
