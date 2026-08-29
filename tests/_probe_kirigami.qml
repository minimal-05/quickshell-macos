// Acceptance probe for the org.kde.kirigami Icon shim. Three icons in a
// never-shown window: a bare app name (must resolve through
// Quickshell.iconPath), a nonexistent name with a resolvable fallback, and a
// mask-coloured svg. check() reports each Image's status.
//   bin/qs-test tests/_probe_kirigami.qml -- kirigami check == ok
import QtQuick
import Quickshell
import Quickshell.Io
import org.kde.kirigami as Kirigami

ShellRoot {
    FloatingWindow {
        id: win
        visible: false
        implicitWidth: 120
        implicitHeight: 40

        Kirigami.Icon {
            id: bare
            source: "Finder"
            width: 32; height: 32
        }
        Kirigami.Icon {
            id: fallbackIcon
            source: "nonexistent-app-xyz"
            fallback: "Finder"
            width: 32; height: 32
        }
        Kirigami.Icon {
            id: mask
            source: "/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns"
            isMask: true
            color: "#ff0000"
            width: 32; height: 32
        }
        Kirigami.Icon {
            id: letter
            source: "nonexistent-app-xyz"
            width: 32; height: 32
        }
    }

    IpcHandler {
        target: "kirigami"

        function check(): string {
            // Kirigami.Icon.status mirrors Image.status: 1 = Ready.
            if (bare.status !== Image.Ready)
                return "bare-not-ready " + bare.status;
            if (fallbackIcon.status !== Image.Ready)
                return "fallback-not-ready " + fallbackIcon.status;
            if (mask.status !== Image.Ready)
                return "mask-not-ready " + mask.status;
            if (!mask.masked)
                return "mask-not-applied";
            if (letter.status !== Image.Error)
                return "letter-status " + letter.status;
            return "ok";
        }

        function dump(): string {
            return JSON.stringify({
                "bare": [bare.status, bare.resolvedSource],
                "fallback": [fallbackIcon.status, fallbackIcon.resolvedSource],
                "mask": [mask.status, mask.masked],
                "letter": [letter.status, letter.resolvedSource]
            });
        }
    }
}
