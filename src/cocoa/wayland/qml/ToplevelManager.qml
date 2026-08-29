// Quickshell.Wayland shim for macOS — ToplevelManager
//
// Upstream this is the wlr-foreign-toplevel-management client. Here it runs
// `yabai -m query --windows` whenever yabai says something changed and
// reconciles the result into a stable set of Toplevel objects, so object
// identity survives across queries and
// `Connections { target: ToplevelManager.toplevels }` behaves.
//
// How it learns about changes: bin/qs-yabai-signals registers one yabai signal
// per event whose action touches $XDG_RUNTIME_DIR/quickshell/yabai/<event>.
// A kqueue watcher (Quickshell.Cocoa.FileWatcher) sees the touch and one
// query runs per event (bursts inside ~10 ms collapse into one). A 30 s poll
// covers the cases no signal reports — yabai restarted and lost its signals,
// a window yabai never saw — and is the only thing that runs on an idle
// desktop.
//
// REAL:
//   toplevels            an ObjectModel-shaped object: `.values` is the live
//                        list (that is how every real config reads it —
//                        `ToplevelManager.toplevels.values.filter(...)`),
//                        plus indexOf() and the upstream insert/remove signals.
//   toplevels.valuesChanged  emitted only when the set actually changes.
//   activeToplevel       the window yabai reports as `has-focus`.
//
// INERT:
//   toplevels is a plain QtObject, NOT a QAbstractListModel. Using it directly
//   as a `model:` for a Repeater/ListView will not work — bind to
//   `ToplevelManager.toplevels.values` instead. Every config surveyed
//   (end-4, caelestia, DankMaterialShell) already does exactly that.
//
// Requires yabai to be running. Only *queries* and *signals* are used, which
// work with SIP enabled; nothing here needs the scripting addition.

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Cocoa

Singleton {
    id: root

    readonly property QtObject toplevels: model
    property Toplevel activeToplevel: null

    // Shim-only. Not part of the upstream API. See the sticky note in _reconcile.
    property int _lastActiveWid: -1

    // Shim-only: the last parsed `yabai -m query --windows`, published only
    // when its text changed. The Quickshell.Hyprland shim reads this instead
    // of running a second query of its own per event.
    property var _rawWindows: []

    // Shim-only: how many window queries have run. Tests read it to prove
    // an idle instance spawns nothing.
    property int _queries: 0

    function refresh(): void {
        root._wantQuery = true;
        settle.restart();
    }

    readonly property QtObject _model: QtObject {
        id: model

        property var values: []
        readonly property int count: values.length

        signal objectInsertedPre(var object, int index)
        signal objectInsertedPost(var object, int index)
        signal objectRemovedPre(var object, int index)
        signal objectRemovedPost(var object, int index)

        function indexOf(object): int {
            return values.indexOf(object);
        }
    }

    readonly property Component _toplevelComponent: Component {
        id: toplevelComponent

        Toplevel {}
    }

    function _screensFor(displayIndex): var {
        // yabai display indices are 1-based and match the order Quickshell
        // lists screens closely enough to be useful; fall back to empty.
        const all = Quickshell.screens;
        const i = (displayIndex ?? 0) - 1;
        return (i >= 0 && i < all.length) ? [all[i]] : [];
    }

    function _apply(win, w): void {
        win.appId = w.app ?? "";
        win.title = w.title ?? "";
        win.activated = w["has-focus"] === true;
        win.minimized = w["is-minimized"] === true;
        win.fullscreen = w["is-native-fullscreen"] === true;
        win.maximized = w["has-fullscreen-zoom"] === true;
        win.screens = root._screensFor(w.display);
    }

    function _reconcile(wins): void {
        const previous = model.values;
        const byId = ({});
        for (let i = 0; i < previous.length; i++)
            byId[previous[i].wid] = previous[i];

        const next = [];
        const inserted = [];

        for (let i = 0; i < wins.length; i++) {
            const w = wins[i];
            if (w.id === undefined)
                continue;

            let win = byId[w.id];
            if (win !== undefined) {
                delete byId[w.id];
            } else {
                win = toplevelComponent.createObject(root, {
                    wid: w.id
                });
                if (win === null)
                    continue;
                inserted.push(win);
            }

            root._apply(win, w);
            next.push(win);
        }

        const removed = [];
        for (const key in byId)
            removed.push(byId[key]);

        // Only touch `values` when the membership or order actually changed —
        // a redundant reset re-creates every delegate bound to it.
        let changed = next.length !== previous.length;
        if (!changed) {
            for (let i = 0; i < next.length; i++) {
                if (next[i] !== previous[i]) {
                    changed = true;
                    break;
                }
            }
        }

        if (changed) {
            for (let i = 0; i < removed.length; i++)
                model.objectRemovedPre(removed[i], previous.indexOf(removed[i]));

            model.values = next;

            for (let i = 0; i < removed.length; i++)
                model.objectRemovedPost(removed[i], -1);

            for (let i = 0; i < inserted.length; i++) {
                const idx = next.indexOf(inserted[i]);
                model.objectInsertedPre(inserted[i], idx);
                model.objectInsertedPost(inserted[i], idx);
            }
        }

        for (let i = 0; i < removed.length; i++) {
            removed[i].closed();
            removed[i].destroy();
        }

        let active = next.find(t => t.activated);

        // Sticky fallback. When one of quickshell's own windows takes focus,
        // yabai reports no window as `has-focus` at all and activeToplevel
        // would flap to null and back every time the user touches the bar.
        // On Wayland a layer surface taking focus really does deactivate the
        // toplevel, but here it is an artifact of asking the wrong oracle, so
        // the last known active window is held until a different one wins.
        if (active === undefined && root._lastActiveWid >= 0) {
            active = next.find(t => t.wid === root._lastActiveWid);
            if (active !== undefined)
                active.activated = true;
        }

        root._lastActiveWid = active !== undefined ? active.wid : -1;
        root.activeToplevel = active !== undefined ? active : null;
    }

    // ------------------------------------------------------------------
    // yabai signals -> signal files -> one query
    // ------------------------------------------------------------------

    // Every event qs-yabai-signals registers. Any of them can change what
    // the window list says (focus, title, minimised, which space, which
    // display), so all of them queue a window query; the Hyprland shim
    // watches the space/display subset for its own queries.
    readonly property list<string> _signalEvents: [
        "space_changed", "space_created", "space_destroyed",
        "window_created", "window_destroyed", "window_focused", "window_moved", "window_resized",
        "window_minimized", "window_deminimized", "window_title_changed",
        "application_front_switched", "application_hidden", "application_visible",
        "display_added", "display_removed", "display_moved", "display_resized", "display_changed",
        "dock_did_restart", "system_woke"
    ]

    // qs exports XDG_RUNTIME_DIR to every instance; qs-yabai-signals bakes
    // the same directory into the signal actions.
    readonly property string _signalDir: {
        const rt = Quickshell.env("XDG_RUNTIME_DIR");
        return (typeof rt === "string" && rt.length > 0) ? rt + "/quickshell/yabai" : "";
    }

    property string _lastText: ""
    property bool _wantQuery: false

    function _onSignal(event: string): void {
        // yabai drops its signals when it restarts; the Dock restarting and
        // the system waking are the moments it is most likely to have done
        // so, and re-installing is two spawns when nothing changed.
        if (event === "dock_did_restart" || event === "system_woke")
            installSignals.running = true;
        root.refresh();
    }

    function _runPending(): void {
        if (root._wantQuery && !query.running) {
            root._wantQuery = false;
            root._queries++;
            query.running = true;
        }
    }

    Process {
        id: installSignals

        running: true
        command: ["qs-yabai-signals", "install"]

        // Also fires when the script is not on PATH (an instance started
        // without `qs`), in which case the 30 s poll is all there is.
        onRunningChanged: if (!running) root.refresh()
    }

    // The content is never read; the touch is the message.
    FileWatcher {
        directory: root._signalDir
        files: root._signalEvents
        onChanged: name => root._onSignal(name)
    }

    // A space switch fires window_focused, window_moved and friends within a
    // few milliseconds of each other; one query serves them all.
    Timer {
        id: settle

        interval: 10
        repeat: false
        onTriggered: root._runPending()
    }

    Process {
        id: query

        command: ["yabai", "-m", "query", "--windows"]

        // A signal that arrived while the query was in flight queues another
        // run, so the state after the burst is always the one published.
        onRunningChanged: if (!running) Qt.callLater(root._runPending)

        stdout: StdioCollector {
            onStreamFinished: {
                if (text === root._lastText)
                    return;
                let wins;
                try {
                    wins = JSON.parse(text);
                } catch (e) {
                    return;
                }
                if (!Array.isArray(wins))
                    return;

                root._lastText = text;
                root._reconcile(wins);
                root._rawWindows = wins;
            }
        }
    }

    // Safety net for what no signal reports (yabai restarted without its
    // signals, a window it never announced). The only spawn on an idle desktop.
    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }
}
