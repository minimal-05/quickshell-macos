pragma Singleton

import QtQuick

// Quickshell.Services.Mpris.MprisLoopState - macOS compatibility shim.
//
// REAL: the values match upstream player.hpp. Declared as a QML `enum`
// because QML forbids capitalised property names.
//
// Writing MprisPlayer.loopState runs `media-control repeat off|track|playlist`
// and the value is read back from the stream's repeatMode (1 off, 2 track,
// 3 playlist). Only apps that publish that key -- Music and Podcasts do,
// Spotify and browsers do not -- get loopSupported = true, so consumers that
// respect it (end-4 does) hide the loop button where it would lie.
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
