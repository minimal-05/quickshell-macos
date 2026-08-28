pragma Singleton

import QtQuick

// Quickshell.Services.Mpris.MprisLoopState - macOS compatibility shim.
//
// REAL: the values match upstream player.hpp. Declared as a QML `enum`
// because QML forbids capitalised property names.
//
// PARTIAL behaviour: writing MprisPlayer.loopState does reach the OS
// (`media-control repeat off|track|playlist`), but MediaRemote gives no way to
// read the current repeat mode back, so the property reflects only what this
// process last wrote and starts at None. MprisPlayer.loopSupported is
// therefore false, which is the honest answer for a write-only control -
// consumers that respect it (end-4 does) hide the loop button rather than
// showing one that lies.
QtObject {
    id: root

    enum State {
        None = 0,
        Track = 1,
        Playlist = 2
    }

    function toString(status: int): string {
        switch (status) {
        case 0:
            return "None";
        case 1:
            return "Track";
        case 2:
            return "Playlist";
        }
        return "Unknown";
    }
}
