// Quickshell.Wayland shim for macOS — ToplevelManager
//
// Upstream this is the wlr-foreign-toplevel-management client. Here it polls
// `yabai -m query --windows` once a second and reconciles the result into a
// stable set of Toplevel objects, so object identity survives across polls and
// `Connections { target: ToplevelManager.toplevels }` behaves.
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
// Requires yabai to be running. Only *queries* are used, which work with SIP
// enabled; nothing here needs the scripting addition.

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property QtObject toplevels: model
    property Toplevel activeToplevel: null

    // Shim-only. Not part of the upstream API. See the sticky note in _reconcile.
    property int _lastActiveWid: -1

    function refresh(): void {
        query.running = true;
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

    Process {
        id: query

        running: true
        command: ["yabai", "-m", "query", "--windows"]

        stdout: StdioCollector {
            onStreamFinished: {
                let wins;
                try {
                    wins = JSON.parse(text);
                } catch (e) {
                    return;
                }
                if (!Array.isArray(wins))
                    return;

                root._reconcile(wins);
            }
        }
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }
}
