// Quickshell.Services.Notifications -- macOS compatibility shim (pure QML, no C++).
//
// Mirrors qs::service::notifications::Notification
// (quickshell/src/services/notifications/notification.hpp). Upstream this is
// QML_UNCREATABLE and populated from the org.freedesktop.Notifications D-Bus
// service; here it is a plain component with the same member names and defaults,
// constructed and updated by NotificationServer for notifications delivered over
// quickshell's IPC socket (see NotificationServer.qml for why D-Bus has no macOS
// equivalent and what does arrive instead).
//
// updateProperties() is a transcription of Notification::updateProperties in
// notification.cpp: urgency, resident, transient, desktop-entry, action-icons
// and the image all derive from `hints` the way they do upstream, and the
// action list is reconciled by identifier so a replacing notification keeps the
// NotificationAction objects a consumer is still holding.
//
// Actions do round-trip. On Linux invoke() raises ActionInvoked on the bus and
// the sending process (notify-send -A) reads it there; here the sender hands us
// a reply path (a FIFO it is blocked reading, or a file) inside the IPC call
// and invoke() writes "<id> action <identifier>" to it. dismiss()/expire()
// write "<id> closed <reason>" when the sender asked to wait for that
// (notify-send -w). Writing goes through a detached `sh` so a FIFO whose
// reader has gone away can never block the shell: opening it O_RDWR succeeds
// without a reader on macOS, and the line is simply discarded.
//
// Note: no `id: ` object id is declared in this file on purpose. The upstream
// type has an `id` PROPERTY (the notification id), which QML lets us declare,
// but an object id of the same name would shadow it inside this file.

import QtQuick
import Quickshell

QtObject {
    property int id: 0
    property bool tracked: false
    readonly property bool lastGeneration: false
    property real expireTimeout: -1
    property string appName: ""
    property string appIcon: ""
    property string summary: ""
    property string body: ""
    property int urgency: NotificationUrgency.Normal
    // `var` rather than `list<NotificationAction>` so that .map()/.filter() work --
    // end-4's Notifications.qml calls notification.actions.map(...) directly.
    property var actions: []
    property bool hasActionIcons: false
    property bool resident: false
    // Upstream's `transient`. `transient` is a reserved word in the QML grammar
    // (the parser rejects `property bool transient`), so the value lives here and
    // Component.onCompleted defines a JS accessor named `transient` on the
    // object: `notification.transient` and `notification["transient"]` then read
    // through to this from both bindings and functions. Only `notification.transient`
    // as a *declaration* is impossible, and no consumer writes it.
    property bool isTransient: false
    property string desktopEntry: ""
    property string image: ""
    property bool hasInlineReply: false
    property string inlineReplyPlaceholder: ""
    property var hints: ({})

    // --- shim-internal (not upstream API) ----------------------------------
    // Where the sender listens for action / close events, "" for none.
    property string replyPath: ""
    // Whether the sender wants the close event too (notify-send -w, or -A while
    // it is still waiting for an action).
    property bool replyOnClose: false
    // NotificationCloseReason once closed; 0 while open (upstream's mCloseReason
    // defaults to Dismissed but the "closed" state is tracked separately there).
    property int closeReason: 0
    readonly property Component actionComponent: Component {
        NotificationAction {}
    }

    signal closed(reason: int)

    Component.onCompleted: {
        Object.defineProperty(this, "transient", {
            get: function () {
                return this.isTransient;
            },
            enumerable: true
        });
    }

    // Upstream: setTracked(false) is equivalent to dismiss(). tracked is also
    // cleared by close() itself, which the closeReason guard makes idempotent.
    onTrackedChanged: {
        if (!tracked)
            close(NotificationCloseReason.Dismissed);
    }

    function expire(): void {
        close(NotificationCloseReason.Expired);
    }

    function dismiss(): void {
        close(NotificationCloseReason.Dismissed);
    }

    function close(reason: int): void {
        if (closeReason !== 0)
            return;
        closeReason = reason;
        tracked = false;
        if (replyOnClose)
            sendReply("closed", String(reason));
        closed(reason);
    }

    function sendInlineReply(replyText: string): void {
        if (!hasInlineReply) {
            console.error("Cannot send reply to notification without inline-reply action");
            return;
        }
        sendReply("reply", replyText);
    }

    // Called by NotificationAction.invoke(); mirrors NotificationAction::invoke.
    function invokeAction(identifier: string): void {
        if (closeReason !== 0) {
            console.error("Cannot invoke destroyed notification", id);
            return;
        }
        sendReply("action", identifier);
        if (!resident)
            close(NotificationCloseReason.Dismissed);
    }

    function sendReply(kind: string, arg: string): void {
        if (replyPath === "")
            return;
        // `sh -c script name path line`: $0=name, $1=path, $2=line. A FIFO is
        // opened read-write so the open cannot block on a departed reader.
        Quickshell.execDetached(["sh", "-c", 'if [ -p "$1" ]; then exec 3<>"$1"; else exec 3>>"$1"; fi; printf "%s\\n" "$2" >&3', "qs-notify-reply", replyPath, id + " " + kind + " " + arg.replace(/\n/g, " ")]);
    }

    function urgencyFrom(value): int {
        switch (typeof value === "string" ? value.toLowerCase() : value) {
        case 0:
        case "0":
        case "low":
            return NotificationUrgency.Low;
        case 2:
        case "2":
        case "critical":
            return NotificationUrgency.Critical;
        default:
            return NotificationUrgency.Normal;
        }
    }

    // Upstream hands anything that is not already a file: URL to the icon image
    // provider. The port's provider resolves names and bundle ids but not
    // arbitrary absolute files, so those become file: URLs, which is what an
    // Image.source consumer ends up loading either way.
    function imageFrom(h): string {
        const path = h["image-path"] ?? h["image_path"] ?? "";
        if (path === "")
            return "";
        if (path.startsWith("file:") || path.startsWith("image:") || path.startsWith("data:"))
            return path;
        if (path.startsWith("/"))
            return "file://" + path;
        return "image://icon/" + path;
    }

    // params: { appName, appIcon, summary, body, expireTimeout, actions, hints,
    //           replyPath, replyOnClose }
    // actions: either the flat freedesktop list [id, text, id, text, ...] or a
    // list of [id, text] pairs.
    function updateProperties(params): void {
        expireTimeout = params.expireTimeout ?? -1;
        appName = params.appName ?? "";
        summary = params.summary ?? "";
        body = params.body ?? "";
        replyPath = params.replyPath ?? "";
        replyOnClose = !!params.replyOnClose;

        const h = (params.hints && typeof params.hints === "object") ? params.hints : ({});
        hasActionIcons = !!h["action-icons"];
        resident = !!h["resident"];
        isTransient = !!h["transient"];
        desktopEntry = String(h["desktop-entry"] ?? "");
        urgency = urgencyFrom(h["urgency"]);

        // Upstream falls back to the desktop entry's icon. On macOS the desktop
        // entry is a bundle id or app name, which the icon provider resolves
        // through LaunchServices, so the entry itself is the icon name.
        let icon = params.appIcon ?? "";
        if (icon === "" && desktopEntry !== "")
            icon = desktopEntry;
        appIcon = icon;
        image = imageFrom(h);
        // Raw pixel hints are D-Bus byte arrays; nothing on this side produces
        // them, and upstream strips them from `hints` regardless.
        const kept = Object.assign({}, h);
        delete kept["image-data"];
        delete kept["image_data"];
        delete kept["icon_data"];
        hints = kept;

        let pairs = [];
        const raw = Array.isArray(params.actions) ? params.actions : [];
        if (raw.length > 0 && Array.isArray(raw[0])) {
            pairs = raw.filter(p => Array.isArray(p) && p.length >= 2).map(p => [String(p[0]), String(p[1])]);
        } else if (raw.length % 2 === 0) {
            for (let i = 0; i < raw.length; i += 2)
                pairs.push([String(raw[i]), String(raw[i + 1])]);
        } else {
            console.warn("Notification", id, "(" + appName + ") sent an action set with an odd number of entries.");
        }

        const next = [];
        const dropped = [];
        let ai = 0;
        for (const [identifier, text] of pairs) {
            if (identifier === "inline-reply") {
                if (hasInlineReply)
                    console.warn("Notification", id, "(" + appName + ") sent an action set with duplicate inline-reply actions.");
                else {
                    hasInlineReply = true;
                    inlineReplyPlaceholder = text;
                }
                continue;
            }
            const existing = ai < actions.length ? actions[ai] : null;
            if (existing && existing.identifier === identifier) {
                existing.text = text;
                next.push(existing);
            } else {
                if (existing)
                    dropped.push(existing);
                next.push(actionComponent.createObject(this, {
                    "identifier": identifier,
                    "text": text,
                    "notification": this
                }));
            }
            ai++;
        }
        for (let i = ai; i < actions.length; i++)
            dropped.push(actions[i]);
        actions = next;
        for (const a of dropped)
            a.destroy();
    }
}
