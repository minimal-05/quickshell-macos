pragma Singleton

import QtQuick

// Quickshell.Services.Mpris.MprisPlaybackState - macOS compatibility shim.
//
// REAL and fully faithful: the values match upstream player.hpp exactly, so
// `player.playbackState == MprisPlaybackState.Playing` behaves identically.
// Declared as a QML `enum` because QML forbids capitalised property names.
//
// Note on semantics: media-control only reports playing / not-playing, so the
// shim's player never reports Stopped while a track is loaded - it reports
// Paused. Stopped means "no now-playing session at all", which is also exactly
// when Mpris.players is empty.
QtObject {
    id: root

    enum State {
        Stopped = 0,
        Playing = 1,
        Paused = 2
    }

    function toString(status: int): string {
        switch (status) {
        case 1:
            return "Playing";
        case 2:
            return "Paused";
        case 0:
            return "Stopped";
        }
        return "Unknown";
    }
}
