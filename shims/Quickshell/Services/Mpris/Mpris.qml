pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Quickshell.Services.Mpris.Mpris - macOS compatibility shim.
//
// Upstream this watches D-Bus for org.mpris.MediaPlayer2.* names and exposes
// one MprisPlayer per player. macOS has no MPRIS and no D-Bus; what it has is
// a single system-wide "now playing" session, which `media-control` reads out
// of Apple's MediaRemote framework.
//
// So: `players` holds exactly one MprisPlayer while a track is loaded, and is
// empty otherwise. `players` is a Quickshell ScriptModel, which gives the same
// `.values` array and Instantiator/Repeater-compatible model that upstream's
// ObjectModel does (ObjectModel itself is uncreatable from QML).
//
// FRAGILITY WORTH KNOWING: Apple entitlement-gated the MediaRemote read path
// in macOS 15.4. media-control works around it by having Apple-signed
// /usr/bin/perl load the adapter framework, which can break on any macOS point
// release. When it does, `players` simply goes empty - consumers see "no
// player", which is a state every MPRIS config already handles.
Singleton {
    id: root

    readonly property ScriptModel players: ScriptModel {
        values: root.__players

        // Upstream's ObjectModel has a Q_INVOKABLE indexOf; ScriptModel does
        // not, and configs (end-4's MprisController) call it.
        function indexOf(object): int {
            return root.__players.indexOf(object);
        }
    }

    // ---- shim internals --------------------------------------------------

    property var __players: []

    // The single MprisPlayer. It always exists; it is only *listed* while a
    // track is loaded, so `players.values` matches upstream semantics.
    readonly property MprisPlayer __player: MprisPlayer {}

    property string __trackKey: ""

    function __present(present: bool): void {
        const listed = root.__players.length > 0;
        if (present === listed)
            return;
        root.__players = present ? [root.__player] : [];
    }

    // Stable positive 31-bit hash, standing in for upstream's uniqueId.
    function __hash(text: string): int {
        let h = 0;
        for (let i = 0; i < text.length; i++)
            h = (h * 31 + text.charCodeAt(i)) | 0;
        return Math.abs(h);
    }

    function __identityFor(bundleId: string): string {
        if (bundleId.startsWith("com.spotify"))
            return "Spotify";
        if (bundleId.includes("iTunes") || bundleId.endsWith(".Music"))
            return "Music";
        if (bundleId.includes("firefox"))
            return "Firefox";
        if (bundleId.includes("Safari"))
            return "Safari";
        if (bundleId.toLowerCase().includes("chrome"))
            return "Chrome";
        if (bundleId.includes("VLC") || bundleId.includes("vlc"))
            return "VLC";
        if (bundleId.length === 0)
            return "Media";

        // com.example.SomeApp -> SomeApp
        const parts = bundleId.split(".");
        return parts[parts.length - 1];
    }

    // `media-control stream` opens with a priming frame of {"payload":{}}
    // before any real state. Honouring it would blank the player for a beat at
    // every startup (and fire a bogus second trackChanged once the real frame
    // lands), so the first empty frame off the stream is discarded. Every
    // later empty frame is honoured, because that is a session genuinely
    // ending.
    property bool __streamPrimed: false

    function __apply(frame: var, fromStream: bool): void {
        if (!frame || typeof frame !== "object")
            return;

        // The stream wraps state in {type, diff, payload}; `get` returns the
        // payload bare. A payload with no title means no now-playing session.
        let p = frame;
        if (frame.payload !== undefined)
            p = frame.payload;
        if (!p || typeof p !== "object")
            p = ({});

        const title = p.title ?? "";

        if (fromStream && !root.__streamPrimed) {
            root.__streamPrimed = true;
            if (title.length === 0)
                return;
        }

        if (title.length === 0) {
            root.__player.__setState(MprisPlaybackState.Stopped);
            root.__present(false);
            root.__trackKey = "";
            return;
        }

        const player = root.__player;
        const album = p.album ?? "";
        const artist = p.artist ?? "";
        const bundleId = p.bundleIdentifier ?? "";
        // Deliberately NOT media-control's `contentItemIdentifier`: Spotify
        // mints a fresh one on every play/pause frame, which would fire a
        // bogus trackChanged (and animate a track transition) each time the
        // user hits pause. Title+album+artist+duration is stable across
        // transport commands and still changes on a genuine track change.
        const key = [bundleId, title, album, artist, Math.round(p.duration ?? 0)].join("|");

        // List the player before announcing the track change, so a consumer
        // watching `players.values[0]` is already connected when the signal
        // fires - the same order upstream produces.
        root.__present(true);

        const changed = key !== root.__trackKey;
        if (changed) {
            root.__trackKey = key;
            player.trackChanged();
        }

        player.bundleId = bundleId;
        player.identity = root.__identityFor(bundleId);
        player.desktopEntry = bundleId;
        player.dbusName = "org.mpris.MediaPlayer2." + root.__identityFor(bundleId).toLowerCase().replace(/[^a-z0-9]/g, "");

        player.trackTitle = title;
        player.trackArtist = artist;
        player.trackAlbum = album;
        player.trackAlbumArtist = "";
        // Artwork arrives as base64 on a separate fetch, not on the stream -- see
        // artworkFetch below. Keep whatever is already on screen until the new
        // file lands, so changing track does not blank the image for a moment.
        player.uniqueId = root.__hash(key);
        player.metadata = {
            "xesam:title": title,
            "xesam:artist": artist.length > 0 ? [artist] : [],
            "xesam:album": album,
            "mpris:length": Math.round((p.duration ?? 0) * 1000000),
            "mpris:trackid": key
        };

        player.length = p.duration ?? 0;
        player.__rebase(p.elapsedTime ?? 0);
        player.__setPosition(p.elapsedTime ?? 0);
        player.__setState(p.playing === true ? MprisPlaybackState.Playing : MprisPlaybackState.Paused);

        if (changed) {
            player.postTrackChanged();
            root.__fetchArtwork();
        }
    }

    // ---- artwork ---------------------------------------------------------

    /// Where the decoded cover for the current track is written.
    readonly property string __artDir: "/tmp/quickshell/media/art"

    /// Bumped per fetch so the filename changes. Qt's image cache is keyed on the
    /// URL, so writing over one path would leave the first cover on screen for
    /// every subsequent track.
    property int __artSerial: 0

    function __fetchArtwork(): void {
        root.__artSerial++;
        artworkFetch.running = false;
        artworkFetch.running = true;
    }

    // media-control can emit the cover, but only as base64 inside the JSON, which
    // is why the stream runs --no-artwork: it would dwarf every other frame. A
    // one-shot fetch on track change is cheap, and decoding it to a file gives
    // Image something it can actually load. mpris:artUrl is a URL upstream too,
    // so consumers need no special case.
    Process {
        id: artworkFetch

        command: ["bash", "-c", `
            set -e
            dir='${root.__artDir}'
            out="$dir/cover-${root.__artSerial}"
            mkdir -p "$dir"
            json=$(media-control get 2>/dev/null) || exit 1
            data=$(printf '%s' "$json" | jq -r '.artworkData // empty')
            [ -n "$data" ] || exit 1
            printf '%s' "$data" | base64 -d > "$out" 2>/dev/null
            [ -s "$out" ] || { rm -f "$out"; exit 1; }
            # Keep only the newest few; a long listening session would otherwise
            # fill the directory one cover at a time.
            ls -1t "$dir"/cover-* 2>/dev/null | tail -n +4 | xargs -I{} rm -f {} 2>/dev/null || true
            printf '%s' "$out"
        `]

        stdout: StdioCollector {
            onStreamFinished: {
                const path = text.trim();
                if (path.length === 0)
                    return;

                const player = root.players.values[0] ?? null;
                if (player !== null)
                    player.trackArtUrl = "file://" + path;
            }
        }
    }

    // ---- processes -------------------------------------------------------

    // Long-lived: one JSON object per line. Artwork is stripped because it
    // dwarfs the rest of the payload and this shim cannot surface it anyway.
    Process {
        id: stream

        running: true
        command: ["media-control", "stream", "--no-diff", "--no-artwork", "--debounce=250"]

        stdout: SplitParser {
            onRead: line => {
                if (!line.trim().startsWith("{"))
                    return;
                try {
                    root.__apply(JSON.parse(line), true);
                } catch (e) {
                // A truncated frame is not worth surfacing; another lands in 250ms.
                }
            }
        }

        onExited: streamRestart.start()
    }

    Timer {
        id: streamRestart

        interval: 3000
        onTriggered: {
            // A fresh stream sends its own priming frame.
            root.__streamPrimed = false;
            stream.running = true;
        }
    }

    // The stream only emits on change, so ask once at startup for whatever is
    // already playing.
    Process {
        running: true
        command: ["media-control", "get", "--no-artwork"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.__apply(JSON.parse(text), false);
                    // __apply only fetches artwork when the track changed, and
                    // whatever is already playing at startup has not changed.
                    root.__fetchArtwork();
                } catch (e) {}
            }
        }
    }
}
