// Acceptance probe for the pasteboard watch (P0-07): counts
// Quickshell.clipboardTextChanged and reports what clipboardText read at the
// time. Driven by tests/clipboard.sh; by hand:
//   bin/qs-test tests/_probe_clipboard.qml --shell     then  echo x | pbcopy
//   bin/quickshell -p tests/_probe_clipboard.qml ipc call clipboard changes
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root
    property int changes: 0
    property string last: ""

    Connections {
        target: Quickshell
        function onClipboardTextChanged() {
            root.changes += 1;
            root.last = Quickshell.clipboardText;
            console.log("clipboardTextChanged", root.changes, JSON.stringify(root.last));
        }
    }

    IpcHandler {
        target: "clipboard"
        function changes(): string { return String(root.changes); }
        function last(): string { return root.last; }
        function text(): string { return Quickshell.clipboardText; }
        function set(t: string): string { Quickshell.clipboardText = t; return "ok"; }
    }
}
