// Quickshell.Hyprland shim (macOS) — HyprlandEvent
//
// Upstream this wraps one line off Hyprland's socket2 event stream.
// There is no such stream on macOS, so the Hyprland singleton *synthesises*
// events by diffing successive yabai polls. The shape (`name`, `data`,
// `parse(n)`) is identical to upstream, and the subset of event names we can
// honestly produce is:
//
//   workspace, workspacev2, focusedmon, activewindow, activewindowv2,
//   openwindow, closewindow, monitoradded, monitorremoved
//
// REAL: name, data, parse().
// INERT: nothing — but note that events arrive on the poll interval (~0.5s),
//        not instantly, and every other Hyprland event name is never emitted.

import QtQuick

QtObject {
    /// The name of the event.
    property string name: ""

    /// The unparsed data of the event.
    property string data: ""

    /// Parse this event with a known number of arguments.
    /// Extra commas past `argumentCount` stay in the last argument, matching
    /// upstream behaviour.
    function parse(argumentCount: int): var {
        if (argumentCount <= 0)
            return [];

        const out = [];
        let rest = data;

        for (let i = 0; i < argumentCount - 1; i++) {
            const idx = rest.indexOf(",");
            if (idx === -1) {
                out.push(rest);
                rest = "";
            } else {
                out.push(rest.slice(0, idx));
                rest = rest.slice(idx + 1);
            }
        }

        out.push(rest);
        return out;
    }
}
