// Quickshell.Hyprland shim (macOS) — Hyprland singleton
//
// Stands in for qs::hyprland::ipc::HyprlandIpcQml. There is no Hyprland and no
// socket2 here; every fact comes from polling yabai:
//
//   yabai -m query --displays  ->  monitors
//   yabai -m query --spaces    ->  workspaces   (space index == workspace id)
//   yabai -m query --windows   ->  toplevels
//
// yabai *queries* work with SIP fully enabled; only its space-manipulation
// features need SIP disabled, and dispatch() avoids those.
//
// REAL:  monitors, workspaces, toplevels, focusedMonitor, focusedWorkspace,
//        activeToplevel, monitorFor(), refreshMonitors(), refreshWorkspaces(),
//        refreshToplevels(), and a useful subset of dispatch() (translation
//        table at the bottom of this file).
// INERT: requestSocketPath / eventSocketPath — empty strings, there are no
//        sockets. usingLua is pinned false, which is also the correct answer:
//        it makes consumer configs emit classic dispatcher strings, which are
//        the only ones this shim can translate.
// APPROXIMATED: rawEvent is synthesised by diffing polls rather than streamed,
//        so it lags by up to one poll interval and only carries the handful of
//        event names listed in HyprlandEvent.qml.
//
// This file is intentionally self-contained: shims cannot import qs.services.

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    // ------------------------------------------------------------------
    // Public API — names and shapes match upstream exactly.
    // ------------------------------------------------------------------

    /// INERT: pinned false. Consumers branch on this to choose dispatcher
    /// syntax, and only the classic (non-lua) strings are translatable here.
    readonly property bool usingLua: false

    /// INERT: no request socket exists on macOS.
    readonly property string requestSocketPath: ""

    /// INERT: no event socket exists on macOS.
    readonly property string eventSocketPath: ""

    /// The currently focused monitor. May be null.
    property var focusedMonitor: null

    /// The currently focused workspace. May be null.
    property var focusedWorkspace: null

    /// The currently focused toplevel. May be null.
    property var activeToplevel: null

    /// ObjectModel-alike. `monitors.values` is an array of HyprlandMonitor.
    readonly property QtObject monitors: QtObject {
        property var values: []
        readonly property int count: values.length
        function indexOf(object: var): int {
            return values.indexOf(object);
        }
    }

    /// ObjectModel-alike, sorted by id. `workspaces.values` is an array of
    /// HyprlandWorkspace.
    readonly property QtObject workspaces: QtObject {
        property var values: []
        readonly property int count: values.length
        function indexOf(object: var): int {
            return values.indexOf(object);
        }
    }

    /// ObjectModel-alike. `toplevels.values` is an array of HyprlandToplevel.
    readonly property QtObject toplevels: QtObject {
        property var values: []
        readonly property int count: values.length
        function indexOf(object: var): int {
            return values.indexOf(object);
        }
    }

    /// Emitted for synthesised events. See HyprlandEvent.qml for the subset.
    signal rawEvent(event: var)

    /// Get the HyprlandMonitor matching a Quickshell screen. May be null.
    function monitorFor(screen: var): var {
        if (!screen)
            return null;

        // Consumers call this while building their own components, which can be
        // before the first yabai query returns. Seed on demand rather than
        // handing back null and making every `.name` in the config throw.
        if (root.monitors.values.length === 0)
            root.seedMonitorsFromScreens();

        const mons = root.monitors.values;
        const byName = mons.find(m => m.name === screen.name);
        if (byName)
            return byName;

        const byGeometry = mons.find(m => m.x === screen.x && m.y === screen.y && m.width === screen.width && m.height === screen.height);
        if (byGeometry)
            return byGeometry;

        return mons.length > 0 ? mons[0] : null;
    }

    function refreshMonitors(): void {
        displayQuery.running = true;
    }

    function refreshWorkspaces(): void {
        spaceQuery.running = true;
    }

    function refreshToplevels(): void {
        windowQuery.running = true;
    }

    /// Execute a Hyprland dispatcher. Translated to yabai / macOS equivalents
    /// where one exists; unknown dispatchers are logged and ignored.
    function dispatch(request: string): void {
        const cmd = String(request ?? "").trim();
        if (cmd.length === 0)
            return;

        // Configs emit these regardless of `usingLua` — end-4 switches
        // workspaces with hl.dsp.focus() unconditionally — so they have to be
        // translated too, not ignored.
        const argv = cmd.startsWith("hl.") ? root.translateLuaDispatch(cmd) : root.translateDispatch(cmd);

        if (argv === null) {
            console.log("Quickshell.Hyprland shim: no macOS equivalent for dispatch:", cmd);
            return;
        }

        if (argv.length === 0)
            return; // deliberately a no-op

        Quickshell.execDetached(argv);
        resettle.restart();
    }


    /// Translate a lua-mode dispatch (`hl.dsp.*`). Returns an argv array, an
    /// empty array for a deliberate no-op, or null when nothing maps.
    function translateLuaDispatch(cmd: string): var {
        // The argument is a lua table literal; pull out the fields we support
        // rather than trying to parse lua properly.
        function field(name) {
            const m = cmd.match(new RegExp(name + '\\s*=\\s*"?([^,"}\\s]+)"?'));
            return m ? m[1] : null;
        }
        function windowId() {
            const addr = field("window");
            if (!addr) return null;
            const hex = addr.replace(/^address:/, "");
            const id = parseInt(hex, 16);
            return isNaN(id) ? null : String(id);
        }

        if (cmd.startsWith("hl.dsp.focus")) {
            const ws = field("workspace");
            if (ws !== null) {
                if (ws === "r+1") return ["sh", "-c", "yabai -m space --focus next || yabai -m space --focus first"];
                if (ws === "r-1") return ["sh", "-c", "yabai -m space --focus prev || yabai -m space --focus last"];
                const idx = root.resolveWorkspaceIndex(ws);
                return idx === null ? null : ["yabai", "-m", "space", "--focus", String(idx)];
            }

            const win = windowId();
            if (win !== null) return ["yabai", "-m", "window", "--focus", win];

            const mon = field("monitor");
            if (mon !== null) {
                const monitor = root.monitors.values.find(m => m.name === mon);
                return monitor ? ["yabai", "-m", "display", "--focus", String(monitor.id + 1)] : [];
            }

            return [];
        }

        if (cmd.startsWith("hl.dsp.window.close")) {
            const win = windowId();
            return win === null ? ["yabai", "-m", "window", "--close"] : ["yabai", "-m", "window", win, "--close"];
        }

        if (cmd.startsWith("hl.dsp.window.move")) {
            const win = windowId();
            const ws = field("workspace");
            if (ws !== null) {
                const idx = root.resolveWorkspaceIndex(ws);
                if (idx === null) return null;
                return win === null
                    ? ["yabai", "-m", "window", "--space", String(idx)]
                    : ["yabai", "-m", "window", win, "--space", String(idx)];
            }

            // Shim-only extension: `target` swaps two windows' slots. yabai
            // refuses to free-position anything the tiling engine manages
            // ("cannot move a managed window"), so warping onto the window
            // already in the wanted slot is how a tiled window is repositioned.
            const target = field("target");
            if (target !== null) {
                const tid = parseInt(target.replace(/^address:/, ""), 16);
                if (win === null || isNaN(tid)) return null;
                return ["yabai", "-m", "window", win, "--warp", String(tid)];
            }

            // Free positioning, which lands only for a floating window — the
            // same windows Hyprland would have accepted this for.
            const x = field("x");
            const y = field("y");
            if (x !== null && y !== null) {
                const ax = Math.round(parseFloat(x));
                const ay = Math.round(parseFloat(y));
                if (isNaN(ax) || isNaN(ay)) return [];
                const argv = ["yabai", "-m", "window"];
                if (win !== null) argv.push(win);
                return argv.concat(["--move", `abs:${ax}:${ay}`]);
            }

            return [];
        }

        // Shim-only extension: resize by moving the bsp fence on a corner. yabai
        // errors ("cannot locate a bsp node fence") rather than no-ops when the
        // window has no fence on the named side, so fall back to the opposite
        // corner — the same edit seen from the other side of the split. Works
        // for floating windows too, and on an inactive space yabai records the
        // change and applies it when that space is next shown.
        if (cmd.startsWith("hl.dsp.window.resize")) {
            const win = windowId();
            if (win === null) return null;

            const dw = parseInt(field("dw") ?? "0", 10);
            const dh = parseInt(field("dh") ?? "0", 10);
            if (isNaN(dw) || isNaN(dh)) return null;
            if (dw === 0 && dh === 0) return [];

            return ["sh", "-c",
                `yabai -m window ${win} --resize bottom_right:${dw}:${dh} `
                + `|| yabai -m window ${win} --resize top_left:${-dw}:${-dh}`];
        }

        // Deliberate no-ops: macOS has no scratchpad workspace, no way to warp
        // the cursor without an extra tool, and no compositor config to poke.
        if (cmd.startsWith("hl.dsp.workspace.toggle_special")) return [];
        if (cmd.startsWith("hl.dsp.cursor")) return [];
        if (cmd.startsWith("hl.config")) return [];
        if (cmd.startsWith("hl.dsp.global")) return [];

        return null;
    }

    // ------------------------------------------------------------------
    // Dispatcher translation. Exposed (not underscored) so a config can
    // inspect or monkeypatch it while porting.
    // ------------------------------------------------------------------

    function translateDispatch(cmd: string): var {
        const sp = cmd.indexOf(" ");
        const verb = (sp === -1 ? cmd : cmd.slice(0, sp)).toLowerCase();
        const arg = sp === -1 ? "" : cmd.slice(sp + 1).trim();

        switch (verb) {
        // ---- workspaces ----
        case "workspace":
        case "focusworkspaceoncurrentmonitor":
            return root.spaceFocusArgv(arg);

        case "movetoworkspace":
        case "movetoworkspacesilent":
            {
                const comma = arg.indexOf(",");
                const wsArg = comma === -1 ? arg : arg.slice(0, comma);
                const sel = comma === -1 ? "" : arg.slice(comma + 1).trim();
                const target = root.resolveWorkspaceIndex(wsArg);
                if (target === null)
                    return null;
                return ["yabai", "-m", "window"].concat(root.windowSelectorArgv(sel)).concat(["--space", String(target)]);
            }

        case "renameworkspace":
            {
                const parts = arg.split(/\s+/);
                const idx = root.resolveWorkspaceIndex(parts[0]);
                if (idx === null)
                    return null;
                return ["yabai", "-m", "space", String(idx), "--label", parts.slice(1).join(" ")];
            }

        // ---- windows ----
        case "killactive":
            return ["yabai", "-m", "window", "--close"];

        case "closewindow":
        case "killwindow":
            return ["yabai", "-m", "window"].concat(root.windowSelectorArgv(arg)).concat(["--close"]);

        case "focuswindow":
            {
                const sel = root.windowSelectorArgv(arg);
                return sel.length === 0 ? null : ["yabai", "-m", "window", "--focus", sel[0]];
            }

        case "togglefloating":
        case "setfloating":
            return ["yabai", "-m", "window"].concat(root.windowSelectorArgv(arg)).concat(["--toggle", "float"]);

        case "fullscreen":
        case "fullscreenstate":
            return ["yabai", "-m", "window", "--toggle", "zoom-fullscreen"];

        case "togglesplit":
            return ["yabai", "-m", "window", "--toggle", "split"];

        case "pin":
            return ["yabai", "-m", "window"].concat(root.windowSelectorArgv(arg)).concat(["--toggle", "sticky"]);

        case "centerwindow":
            return ["yabai", "-m", "window", "--grid", "6:6:1:1:4:4"];

        case "movefocus":
            {
                const dir = root.directionFor(arg);
                return dir === null ? null : ["yabai", "-m", "window", "--focus", dir];
            }

        case "movewindow":
            {
                const dir = root.directionFor(arg);
                return dir === null ? null : ["yabai", "-m", "window", "--warp", dir];
            }

        case "swapwindow":
            {
                const dir = root.directionFor(arg);
                return dir === null ? null : ["yabai", "-m", "window", "--swap", dir];
            }

        case "cyclenext":
            return ["yabai", "-m", "window", "--focus", arg.indexOf("prev") !== -1 ? "prev" : "next"];

        case "cycleprev":
            return ["yabai", "-m", "window", "--focus", "prev"];

        // ---- monitors / session ----
        case "focusmonitor":
            {
                const n = parseInt(arg, 10);
                if (!isNaN(n))
                    return ["yabai", "-m", "display", "--focus", String(n)];
                if (arg === "+1" || arg === "next")
                    return ["yabai", "-m", "display", "--focus", "next"];
                if (arg === "-1" || arg === "prev")
                    return ["yabai", "-m", "display", "--focus", "prev"];
                return null;
            }

        case "dpms":
            // Only "off" is expressible: macOS can sleep displays but not wake
            // them from a shell command, and any input wakes them anyway.
            return arg.startsWith("off") ? ["pmset", "displaysleepnow"] : [];

        case "exec":
            return ["sh", "-c", arg];

        case "exit":
            // Deliberate no-op: the Hyprland meaning is "quit the compositor",
            // whose macOS analogue would be logging the user out.
            console.log("Quickshell.Hyprland shim: refusing to translate 'exit' (would log the user out)");
            return [];

        default:
            return null;
        }
    }

    /// yabai argv for focusing a Hyprland workspace argument. Uses a shell
    /// fallback for the relative forms so that next/prev wrap around instead of
    /// erroring at the ends.
    function spaceFocusArgv(arg: string): var {
        const a = arg.trim();

        if (a.length === 0)
            return null;

        if (a.startsWith("special"))
            return null; // no macOS analogue of scratchpad workspaces

        if (a === "previous" || a === "previous_per_monitor")
            return ["yabai", "-m", "space", "--focus", "recent"];

        const rel = a.match(/^(?:[rem])?([+-])(\d+)$/);
        if (rel) {
            const forward = rel[1] === "+";
            const dir = forward ? "next" : "prev";
            const wrap = forward ? "first" : "last";
            return ["sh", "-c", `for i in $(seq 1 ${rel[2]}); do yabai -m space --focus ${dir} || yabai -m space --focus ${wrap}; done`];
        }

        const n = root.resolveWorkspaceIndex(a);
        return n === null ? null : ["yabai", "-m", "space", "--focus", String(n)];
    }

    /// Resolve a Hyprland workspace argument to an absolute yabai space index,
    /// or null when it cannot be expressed.
    function resolveWorkspaceIndex(arg: string): var {
        const a = String(arg ?? "").trim();
        const count = root.workspaces.values.length;
        const current = root.focusedWorkspace ? root.focusedWorkspace.id : 1;

        const abs = a.match(/^\d+$/);
        if (abs)
            return parseInt(a, 10);

        const rel = a.match(/^(?:[rem])?([+-])(\d+)$/);
        if (rel && count > 0) {
            const delta = parseInt(rel[2], 10) * (rel[1] === "+" ? 1 : -1);
            let target = current + delta;
            while (target > count)
                target -= count;
            while (target < 1)
                target += count;
            return target;
        }

        // Named workspaces: yabai spaces can carry a label.
        const named = root.workspaces.values.find(w => w.name === a);
        return named ? named.id : null;
    }

    /// Convert a Hyprland window selector into leading yabai argv (a window id,
    /// or nothing at all which yabai reads as "the focused window").
    function windowSelectorArgv(sel: string): var {
        const s = String(sel ?? "").trim();

        if (s.length === 0 || s === "activewindow")
            return [];

        const addr = s.match(/^address:\s*(?:0x)?([0-9a-fA-F]+)$/);
        if (addr) {
            const id = parseInt(addr[1], 16);
            return isNaN(id) ? [] : [String(id)];
        }

        // class:/title:/pid: selectors are resolved against the last poll.
        const byClass = s.match(/^(?:class|initialclass):(.*)$/);
        if (byClass) {
            const re = new RegExp(byClass[1]);
            const hit = root.toplevels.values.find(t => re.test(t.appName));
            return hit ? [String(parseInt(hit.address, 16))] : [];
        }

        const byTitle = s.match(/^(?:title|initialtitle):(.*)$/);
        if (byTitle) {
            const re = new RegExp(byTitle[1]);
            const hit = root.toplevels.values.find(t => re.test(t.title));
            return hit ? [String(parseInt(hit.address, 16))] : [];
        }

        return [];
    }

    function directionFor(arg: string): var {
        switch (String(arg ?? "").trim().charAt(0).toLowerCase()) {
        case "l":
            return "west";
        case "r":
            return "east";
        case "u":
        case "t":
            return "north";
        case "d":
        case "b":
            return "south";
        default:
            return null;
        }
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    readonly property var monitorComponent: Qt.createComponent(Qt.resolvedUrl("HyprlandMonitor.qml"), Component.PreferSynchronous)
    readonly property var workspaceComponent: Qt.createComponent(Qt.resolvedUrl("HyprlandWorkspace.qml"), Component.PreferSynchronous)
    readonly property var toplevelComponent: Qt.createComponent(Qt.resolvedUrl("HyprlandToplevel.qml"), Component.PreferSynchronous)
    readonly property var eventComponent: Qt.createComponent(Qt.resolvedUrl("HyprlandEvent.qml"), Component.PreferSynchronous)

    property var rawDisplays: []
    property var rawSpaces: []
    property var rawWindows: []
    property var eventObject: null

    /// Raw text of the last poll of each query. Polls that return byte-identical
    /// output are dropped before rebuild(), because reassigning `values` on
    /// every tick makes animating bar delegates flicker — the same guard
    /// Spaces.qml uses.
    property string lastDisplayText: ""
    property string lastSpaceText: ""
    property string lastWindowText: ""

    /// Last-seen values, for synthesising events.
    property string lastEventWorkspace: ""
    property string lastEventMonitor: ""
    property string lastEventWindow: ""
    property var lastEventAddresses: []

    function emitEvent(name: string, data: string): void {
        if (!root.eventObject)
            root.eventObject = root.eventComponent.createObject(root);
        if (!root.eventObject)
            return;

        root.eventObject.name = name;
        root.eventObject.data = data;
        root.rawEvent(root.eventObject);
    }

    // The first yabai query is async, so without this the monitor list is empty
    // for the first few hundred milliseconds and every consumer doing
    // `Hyprland.monitorFor(screen).name` throws on null. Seed one monitor per
    // Quickshell screen synchronously at startup; rebuild() then reconciles
    // them against yabai by geometry.
    Component.onCompleted: root.seedMonitorsFromScreens()

    function seedMonitorsFromScreens(): void {
        if (root.monitors.values.length > 0)
            return;

        const seeded = [];
        const screens = Quickshell.screens;

        for (let i = 0; i < screens.length; i++) {
            const screen = screens[i];
            // Hyprland numbers monitors from 0 and consumers index arrays
            // with the id (HyprlandData.monitors[monitor.id]), so the yabai
            // display index (1-based) is shifted down rather than used as-is.
            const mon = root.monitorComponent.createObject(root, {
                id: i
            });
            if (!mon)
                continue;

            mon.name = screen.name;
            mon.description = screen.name;
            mon.x = screen.x;
            mon.y = screen.y;
            // Hyprland reports monitor size in PHYSICAL pixels with `scale` as
            // the divisor, so consumers doing `width / scale` get logical size.
            // QScreen gives logical size, so multiply back up. `scale` stays at
            // the device pixel ratio: the region screenshot path multiplies
            // logical coordinates by it to crop a device-resolution capture.
            mon.width = Math.round(screen.width * screen.devicePixelRatio);
            mon.height = Math.round(screen.height * screen.devicePixelRatio);
            mon.scale = screen.devicePixelRatio;
            mon.focused = i === 0;
            seeded.push(mon);
        }

        if (seeded.length > 0)
            root.monitors.values = seeded;
    }

    function rebuild(): void {
        // ---- monitors ----
        const screens = Quickshell.screens;
        const oldMonitors = root.monitors.values.slice();
        const monitorById = {};
        for (const m of oldMonitors)
            monitorById[m.id] = m;

        const newMonitors = [];
        for (let i = 0; i < root.rawDisplays.length; i++) {
            const d = root.rawDisplays[i];
            const frame = d.frame ?? {};
            // yabai display indices are 1-based; Hyprland monitor ids are 0-based.
            const monId = d.index - 1;
            let mon = monitorById[monId];
            if (!mon) {
                mon = root.monitorComponent.createObject(root, {
                    id: monId
                });
                if (!mon)
                    continue;
            }
            delete monitorById[monId];

            // Prefer the Quickshell screen's own name/geometry so that
            // `Quickshell.screens.find(s => s.name === monitor.name)` works.
            const screen = screens.find(s => s.x === Math.round(frame.x ?? -1) && s.y === Math.round(frame.y ?? -1) && s.width === Math.round(frame.w ?? -1) && s.height === Math.round(frame.h ?? -1)) ?? screens[i] ?? null;

            mon.name = screen ? screen.name : ("display-" + d.index);
            mon.description = mon.name;
            mon.x = screen ? screen.x : Math.round(frame.x ?? 0);
            mon.y = screen ? screen.y : Math.round(frame.y ?? 0);
            // Hyprland reports monitor size in PHYSICAL pixels with `scale` as
            // the divisor, so consumers doing `width / scale` get logical size.
            // QScreen gives logical size, so multiply back up. `scale` stays at
            // the device pixel ratio: the region screenshot path multiplies
            // logical coordinates by it to crop a device-resolution capture.
            mon.width = screen ? Math.round(screen.width * screen.devicePixelRatio) : Math.round(frame.w ?? 0);
            mon.height = screen ? Math.round(screen.height * screen.devicePixelRatio) : Math.round(frame.h ?? 0);
            mon.scale = screen ? screen.devicePixelRatio : 1.0;
            mon.focused = d["has-focus"] === true;
            mon.lastIpcObject = d;
            newMonitors.push(mon);
        }

        const goneMonitors = Object.keys(monitorById);

        // ---- workspaces ----
        const oldWorkspaces = root.workspaces.values.slice();
        const workspaceById = {};
        for (const w of oldWorkspaces)
            workspaceById[w.id] = w;

        const newWorkspaces = [];
        const workspaceLookup = {};
        for (const s of root.rawSpaces) {
            let ws = workspaceById[s.index];
            if (!ws) {
                ws = root.workspaceComponent.createObject(root, {
                    id: s.index
                });
                if (!ws)
                    continue;
            }
            delete workspaceById[s.index];

            const mon = newMonitors.find(m => m.id === s.display - 1) ?? null;
            ws.ipc = root;
            ws.name = (s.label && s.label.length > 0) ? s.label : String(s.index);
            ws.active = s["is-visible"] === true;
            ws.focused = s["has-focus"] === true;
            ws.hasFullscreen = s["is-native-fullscreen"] === true;
            ws.monitor = mon;
            ws.lastIpcObject = s;
            ws.toplevels.values = [];
            newWorkspaces.push(ws);
            workspaceLookup[s.index] = ws;
        }
        newWorkspaces.sort((a, b) => a.id - b.id);

        for (const mon of newMonitors) {
            const visible = newWorkspaces.find(w => w.monitor === mon && w.active) ?? null;
            mon.activeWorkspace = visible;
        }

        // ---- toplevels ----
        const oldToplevels = root.toplevels.values.slice();
        const toplevelByAddress = {};
        for (const t of oldToplevels)
            toplevelByAddress[t.address] = t;

        const newToplevels = [];
        const addresses = [];
        for (const w of root.rawWindows) {
            const address = Number(w.id).toString(16);
            addresses.push(address);

            let top = toplevelByAddress[address];
            if (!top) {
                top = root.toplevelComponent.createObject(root, {
                    address: address
                });
                if (!top)
                    continue;
            }
            delete toplevelByAddress[address];

            const ws = workspaceLookup[w.space] ?? null;
            top.title = w.title ?? "";
            top.activated = w["has-focus"] === true;
            top.workspace = ws;
            top.monitor = ws ? ws.monitor : (newMonitors.find(m => m.id === w.display - 1) ?? null);
            top.lastIpcObject = w;
            newToplevels.push(top);

            if (ws)
                ws.toplevels.values = ws.toplevels.values.concat([top]);
        }

        // ---- publish ----
        root.monitors.values = newMonitors;
        root.workspaces.values = newWorkspaces;
        root.toplevels.values = newToplevels;

        root.focusedMonitor = newMonitors.find(m => m.focused) ?? (newMonitors.length > 0 ? newMonitors[0] : null);
        root.focusedWorkspace = newWorkspaces.find(w => w.focused) ?? null;
        root.activeToplevel = newToplevels.find(t => t.activated) ?? null;

        // ---- destroy orphans, after nothing points at them any more ----
        for (const key of goneMonitors) {
            root.emitEvent("monitorremoved", monitorById[key].name);
            monitorById[key].destroy();
        }
        for (const key of Object.keys(workspaceById))
            workspaceById[key].destroy();
        for (const key of Object.keys(toplevelByAddress))
            toplevelByAddress[key].destroy();

        root.synthesiseEvents(addresses);
    }

    /// Diff against the previous poll and emit the events upstream would have
    /// streamed off socket2. Best-effort: names match, timing does not.
    function synthesiseEvents(addresses: var): void {
        const ws = root.focusedWorkspace;
        const wsName = ws ? ws.name : "";
        if (wsName !== root.lastEventWorkspace) {
            root.lastEventWorkspace = wsName;
            root.emitEvent("workspace", wsName);
            root.emitEvent("workspacev2", (ws ? ws.id : -1) + "," + wsName);
        }

        const mon = root.focusedMonitor;
        const monName = mon ? mon.name : "";
        if (monName !== root.lastEventMonitor) {
            root.lastEventMonitor = monName;
            root.emitEvent("focusedmon", monName + "," + wsName);
        }

        const top = root.activeToplevel;
        const topKey = top ? (top.address + "," + top.title) : "";
        if (topKey !== root.lastEventWindow) {
            root.lastEventWindow = topKey;
            root.emitEvent("activewindow", (top ? top.appName : "") + "," + (top ? top.title : ""));
            root.emitEvent("activewindowv2", top ? top.address : "");
        }

        for (const a of addresses)
            if (root.lastEventAddresses.indexOf(a) === -1)
                root.emitEvent("openwindow", a);

        for (const a of root.lastEventAddresses)
            if (addresses.indexOf(a) === -1)
                root.emitEvent("closewindow", a);

        root.lastEventAddresses = addresses;
    }

    function parseJson(text: string): var {
        try {
            const value = JSON.parse(text);
            return Array.isArray(value) ? value : null;
        } catch (e) {
            return null;
        }
    }

    Process {
        id: displayQuery

        running: true
        command: ["yabai", "-m", "query", "--displays"]

        stdout: StdioCollector {
            onStreamFinished: {
                if (text === root.lastDisplayText)
                    return;
                const value = root.parseJson(text);
                if (value === null)
                    return;
                root.lastDisplayText = text;
                root.rawDisplays = value;
                root.rebuild();
            }
        }
    }

    Process {
        id: spaceQuery

        running: true
        command: ["yabai", "-m", "query", "--spaces"]

        stdout: StdioCollector {
            onStreamFinished: {
                if (text === root.lastSpaceText)
                    return;
                const value = root.parseJson(text);
                if (value === null)
                    return;
                root.lastSpaceText = text;
                root.rawSpaces = value;
                root.rebuild();
            }
        }
    }

    Process {
        id: windowQuery

        running: true
        command: ["yabai", "-m", "query", "--windows"]

        stdout: StdioCollector {
            onStreamFinished: {
                if (text === root.lastWindowText)
                    return;
                const value = root.parseJson(text);
                if (value === null)
                    return;
                root.lastWindowText = text;
                root.rawWindows = value;
                root.rebuild();
            }
        }
    }

    /// Fast re-poll right after a dispatch, so the bar catches up immediately
    /// instead of waiting out the normal interval.
    Timer {
        id: resettle

        interval: 120
        repeat: false
        onTriggered: {
            root.refreshWorkspaces();
            root.refreshToplevels();
        }
    }

    Timer {
        id: spaceTimer

        interval: 500
        running: true
        repeat: true
        onTriggered: root.refreshWorkspaces()
    }

    Timer {
        id: windowTimer

        interval: 1000
        running: true
        repeat: true
        onTriggered: root.refreshToplevels()
    }

    Timer {
        id: displayTimer

        interval: 5000
        running: true
        repeat: true
        onTriggered: root.refreshMonitors()
    }
}

// ---------------------------------------------------------------------------
// dispatch() translation table
//
//   Hyprland dispatcher                 macOS / yabai equivalent
//   ----------------------------------  ------------------------------------
//   workspace N                         yabai -m space --focus N
//   workspace r±n / e±n / m±n / ±n      yabai -m space --focus next|prev,
//                                       looped n times, wrapping to first|last
//   workspace previous                  yabai -m space --focus recent
//   workspace special[:name]            (none — logged, ignored)
//   focusworkspaceoncurrentmonitor X    same as `workspace X`
//   movetoworkspace N[,SEL]             yabai -m window [ID] --space N
//   movetoworkspacesilent N[,SEL]       same (macOS has no silent variant)
//   renameworkspace N NAME              yabai -m space N --label NAME
//   killactive                          yabai -m window --close
//   closewindow SEL / killwindow SEL    yabai -m window [ID] --close
//   focuswindow SEL                     yabai -m window --focus ID
//   togglefloating [SEL]                yabai -m window [ID] --toggle float
//   fullscreen / fullscreenstate        yabai -m window --toggle zoom-fullscreen
//   togglesplit                         yabai -m window --toggle split
//   pin [SEL]                           yabai -m window [ID] --toggle sticky
//   centerwindow                        yabai -m window --grid 6:6:1:1:4:4
//   movefocus l|r|u|d                   yabai -m window --focus west|east|north|south
//   movewindow l|r|u|d                  yabai -m window --warp  west|east|north|south
//   swapwindow l|r|u|d                  yabai -m window --swap  west|east|north|south
//   cyclenext [prev]                    yabai -m window --focus next|prev
//   cycleprev                           yabai -m window --focus prev
//   focusmonitor N|next|prev            yabai -m display --focus N|next|prev
//   dpms off                            pmset displaysleepnow
//   dpms on                             no-op (any input wakes the display)
//   exec CMD                            sh -c CMD
//   exit                                no-op, logged (would log the user out)
//   anything else                       no-op, logged
//
// Window selectors understood: `address:0xHEX` (hex of the yabai window id),
// `class:`/`initialclass:` and `title:`/`initialtitle:` regexes resolved
// against the last poll, `activewindow`, and empty (= focused window).
// ---------------------------------------------------------------------------
