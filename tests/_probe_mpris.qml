// Acceptance probe for the Mpris shim. With a now-playing session loaded
// (anything in Spotify/Music, playing or paused) players.values[0].trackTitle
// is non-empty; with none, players is empty and check() says so.
//   bin/qs-test tests/_probe_mpris.qml -- mpris check == ok
//   bin/qs-test tests/_probe_mpris.qml -- mpris dump
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris

ShellRoot {
    // A QML singleton is instantiated on first reference, so touch it at load:
    // otherwise the stream only starts with the first ipc call.
    Component.onCompleted: void Mpris.players

    IpcHandler {
        target: "mpris"

        function check(): string {
            const p = Mpris.players.values[0] ?? null;
            if (p === null)
                return "no-player";
            if (p.trackTitle.length === 0)
                return "empty-title";
            if (p.identity.length === 0)
                return "empty-identity";
            if (!(p.length > 0))
                return "bad-length";
            if (p.position < 0 || p.position > p.length + 1)
                return "bad-position " + p.position;
            if (p.loopSupported !== ("mpris:x-repeatMode" in p.metadata))
                return "loop-honesty";
            if (p.shuffleSupported !== ("mpris:x-shuffleMode" in p.metadata))
                return "shuffle-honesty";
            if (p.rate !== 1 && !(p.minRate < p.maxRate))
                return "rate-honesty";
            return "ok";
        }

        function title(): string {
            return Mpris.players.values[0]?.trackTitle ?? "";
        }

        function dump(): string {
            const p = Mpris.players.values[0] ?? null;
            if (p === null)
                return "{}";
            const out = {};
            for (const k of ["identity", "trackTitle", "trackArtist", "trackAlbum", "isPlaying", "position", "length", "rate", "minRate", "maxRate", "loopState", "loopSupported", "shuffle", "shuffleSupported", "trackArtUrl", "bundleId", "metadata"])
                out[k] = p[k];
            return JSON.stringify(out);
        }
    }
}
