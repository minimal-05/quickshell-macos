// Acceptance probe for ScreencopyView (P1-05, ScreenCaptureKit in-process).
//
// Shows one small panel with a ScreencopyView and answers questions about it
// over IPC, so tests/screencopy.sh can assert on the view's own state instead
// of on screenshots (which need the same TCC grant the view does).
//
//   bin/qs-test tests/_probe_screencopy.qml -- screencopy status
//   bin/qs-test tests/_probe_screencopy.qml -- screencopy dump
//
// Starts capturing a still of the first screen at load, so the permission /
// still path is exercised without any call.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    property var source: Quickshell.screens[0]
    property int stoppedCount: 0

    // The ToplevelManager singleton only starts polling yabai once something
    // references it; touch it at load so firstWindow() has an answer soon.
    Component.onCompleted: void ToplevelManager.toplevels

    PanelWindow {
        id: panel

        anchors {
            bottom: true
            right: true
        }
        margins {
            bottom: 60
            right: 20
        }
        implicitWidth: 240
        implicitHeight: 150
        color: "#88000000"

        ScreencopyView {
            id: view

            anchors.fill: parent
            captureSource: root.source
            live: false
            onStopped: root.stoppedCount++
        }
    }

    IpcHandler {
        target: "screencopy"

        function status(): string {
            return view.status;
        }

        function hasContent(): string {
            return String(view.hasContent);
        }

        function frames(): string {
            return String(view.frameCount);
        }

        function sourceSize(): string {
            return view.sourceSize.width + "x" + view.sourceSize.height;
        }

        function dump(): string {
            return JSON.stringify({
                status: view.status,
                hasContent: view.hasContent,
                sourceSize: [view.sourceSize.width, view.sourceSize.height],
                frames: view.frameCount,
                live: view.live,
                implicitSize: [view.implicitWidth, view.implicitHeight],
                stopped: root.stoppedCount,
                source: root.source === null ? "null" : (root.source.wid !== undefined ? "window " + root.source.wid : "screen")
            });
        }

        // Pixel size of the first screen, for the display-source assertion.
        function screenInfo(): string {
            const s = Quickshell.screens[0];
            return Math.round(s.width * s.devicePixelRatio) + "x" + Math.round(s.height * s.devicePixelRatio) + "@" + s.devicePixelRatio;
        }

        function screen(): string {
            root.source = Quickshell.screens[0];
            return "ok";
        }

        // yabai window id (the CGWindowID) of the first non-minimized toplevel
        // the ToplevelManager shim knows, or "none".
        function firstWindow(): string {
            const t = ToplevelManager.toplevels.values.find(t => !t.minimized && t.appId !== "quickshell");
            return t ? String(t.wid) : "none";
        }

        function window(wid: int): string {
            const t = ToplevelManager.toplevels.values.find(t => t.wid === wid);
            if (!t)
                return "no-toplevel";
            root.source = t;
            return "ok";
        }

        function live(on: bool): string {
            view.live = on;
            return "ok";
        }

        function cursor(on: bool): string {
            view.paintCursor = on;
            return "ok";
        }

        function constrain(w: int, h: int): string {
            view.constraintSize = Qt.size(w, h);
            return "ok";
        }

        function capture(): string {
            view.captureFrame();
            return "ok";
        }

        function stop(): string {
            view.stop();
            return "ok";
        }

        function clear(): string {
            root.source = null;
            return "ok";
        }

        // Not hide()/show(): `show` is an `ipc` subcommand and the CLI grabs it.
        function hidePanel(): string {
            panel.visible = false;
            return "ok";
        }

        function showPanel(): string {
            panel.visible = true;
            return "ok";
        }
    }
}
