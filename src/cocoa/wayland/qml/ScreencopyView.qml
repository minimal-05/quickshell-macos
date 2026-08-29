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

    readonly property bool hasContent: root.front.status === Image.Ready
    readonly property size sourceSize: root.front.sourceSize

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

    // Shim-only: fixed per-view stagger for the live-capture timer.
    readonly property int phase: Math.floor(Math.random() * 900)

    onWindowIdChanged: {
        frameA.source = "";
        frameB.source = "";
        root.front = frameA;
        root.captureFrame();
    }

    onVisibleChanged: if (root.visible) root.captureFrame()

    Component.onCompleted: if (root.visible) root.captureFrame()

    // Two frames, swapped. qs-window-thumbs rewrites the same path every time,
    // so the only way to re-read it is to clear the source first — and clearing
    // the frame that is on screen is what made every refresh blink. The new
    // frame loads into the spare one, underneath, and is raised only once it is
    // ready, so the old frame is never taken away from the viewer.
    //
    // Deliberately a hard swap and not a cross-fade: fading one frame up while
    // fading the other down leaves both partly transparent midway, so the
    // background bleeds through and the tile pulses once per capture. Two
    // opaque frames an instant apart need no transition anyway.
    property Image front: frameA
    readonly property Image back: root.front === frameA ? frameB : frameA

    // Wrapped, so the z used to order the two frames stays local. A consumer
    // adds its own children to this view (overlays, icons); a bare z: 1 on a
    // frame would raise it above those too.
    Item {
        anchors.fill: parent

        Image {
            id: frameA
            anchors.fill: parent
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true
            cache: false
            z: root.front === frameA ? 1 : 0
            onStatusChanged: if (status === Image.Ready) root.front = frameA;
        }

        Image {
            id: frameB
            anchors.fill: parent
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true
            cache: false
            z: root.front === frameB ? 1 : 0
            onStatusChanged: if (status === Image.Ready) root.front = frameB;
        }
    }

    Timer {
        running: root.live && root.visible && root.capturable
        // One screencapture subprocess per window, so an overview full of
        // windows firing on the same tick is a stampede that shows up as jank.
        // A per-view phase offset spreads them over the interval instead.
        interval: 2000 + root.phase
        repeat: true
        onTriggered: root.captureFrame()
    }

    Process {
        id: capture
        command: ["qs-window-thumbs", String(root.windowId)]

        stdout: StdioCollector {
            onStreamFinished: {
                // "<changed> <path>" — the flag leads so a path containing a
                // space still parses.
                const line = text.trim();
                const split = line.indexOf(" ");
                if (split === -1) return;

                const changed = line.slice(0, split) === "1";
                const path = line.slice(split + 1);
                if (path === "") return;

                // Nothing new to show, and something already on screen to keep.
                if (!changed && root.hasContent) return;

                // Clearing first is what forces the re-read; `cache: false`
                // alone does not, because the URL has not changed. This is
                // the off-screen frame, so the blank is never seen.
                const frame = root.back;
                frame.source = "";
                frame.source = "file://" + path;
            }
        }
    }
}
