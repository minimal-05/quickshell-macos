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
//
// LIFETIME: the stream runs under a tiny sh wrapper whose only job is to take
// the adapter down with the shell. The adapter only writes on a now-playing
// change, so a dead shell's closed stdout pipe went unnoticed for hours and
// the audit found 16 orphaned perl interpreters at ~10 MB each. The wrapper
// holds the shell's stdin pipe open instead: the kernel closes it the moment
// the shell dies, however it dies, and `cat` seeing EOF is the kill signal.
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

    // bundle id -> display name. Each bundle costs one `lsappinfo` for the
    // shell's lifetime; a miss (app not running, which the now-playing app
    // rarely is) is cached too, as the heuristic name, so it is never retried
    // per frame.
    property var __names: ({})

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

    // Fallback for a bundle LaunchServices cannot name (not running).
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

    function __lookupName(bundleId: string): void {
        if (bundleId.length === 0 || bundleId in root.__names || nameProc.running)
            return;
        nameProc.bundle = bundleId;
        nameProc.command = ["lsappinfo", "info", "-only", "name", bundleId];
        nameProc.running = true;
    }

    // media-control's repeat modes: 1 off, 2 track, 3 playlist.
    function __loopFor(mode: int): int {
        return mode === 2 ? MprisLoopState.Track : mode === 3 ? MprisLoopState.Playlist : MprisLoopState.None;
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
        const playing = p.playing === true;
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

        root.__lookupName(bundleId);
        player.bundleId = bundleId;
        player.identity = root.__names[bundleId] ?? root.__identityFor(bundleId);
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

        // A key is only in the frame when MediaRemote knows the value, and
        // that is exactly when a control for it would tell the truth: Music
        // and Podcasts publish repeat/shuffle, Spotify and browsers do not.
        // A key that is present is mirrored into metadata under an mpris:x-
        // name so consumers (and tests/_probe_mpris.qml) can see why a
        // control is offered.
        const hasRepeat = typeof p.repeatMode === "number";
        const hasShuffle = typeof p.shuffleMode === "number";
        const hasRate = typeof p.playbackRate === "number";
        player.__setLoop(hasRepeat ? root.__loopFor(p.repeatMode) : MprisLoopState.None, hasRepeat);
        // shuffleMode: 1 off, 2 albums, 3 tracks.
        player.__setShuffle(hasShuffle && p.shuffleMode > 1, hasShuffle);
        // MediaRemote reports playbackRate 0 while paused; that is the state,
        // not the speed, so a paused frame keeps the last known rate.
        player.__setRate(hasRate && p.playbackRate > 0 ? p.playbackRate : player.rate, hasRate);

        const metadata = {
            "xesam:title": title,
            "xesam:artist": artist.length > 0 ? [artist] : [],
            "xesam:album": album,
            "mpris:length": Math.round((p.duration ?? 0) * 1000000),
            "mpris:trackid": key,
            "mpris:artUrl": changed ? "" : player.trackArtUrl
        };
        if (typeof p.trackNumber === "number")
            metadata["xesam:trackNumber"] = p.trackNumber;
        if (p.mediaType !== undefined)
            metadata["mpris:x-mediaType"] = p.mediaType;
        if (hasRepeat)
            metadata["mpris:x-repeatMode"] = p.repeatMode;
        if (hasShuffle)
            metadata["mpris:x-shuffleMode"] = p.shuffleMode;
        if (hasRate)
            metadata["mpris:x-playbackRate"] = p.playbackRate;
        player.metadata = metadata;

        player.length = p.duration ?? 0;

        // elapsedTime is the position as of `timestamp` (the last transport
        // event), not as of this frame, so a frame that arrives late -- or a
        // startup `get` against a session that has been playing for minutes --
        // is rebased to now before it becomes the interpolation origin.
        let elapsed = p.elapsedTime ?? 0;
        const stamp = typeof p.timestamp === "string" ? Date.parse(p.timestamp) : NaN;
        if (playing && !isNaN(stamp))
            elapsed += Math.max(0, (Date.now() - stamp) / 1000) * player.rate;
        if (player.length > 0)
            elapsed = Math.min(elapsed, player.length);
        player.__rebase(elapsed);
        player.__setPosition(elapsed);
        player.__setState(playing ? MprisPlaybackState.Playing : MprisPlaybackState.Paused);

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
                if (player !== null) {
                    player.trackArtUrl = "file://" + path;
                    player.metadata = Object.assign({}, player.metadata, {
                        "mpris:artUrl": player.trackArtUrl
                    });
                }
            }
        }
    }

    // ---- processes -------------------------------------------------------

    // Deliberately backslash-free: a JS template literal, where a stray escape
    // would be eaten before sh saw it. fd 3 is the shell's stdin pipe, which
    // background jobs would otherwise get as /dev/null. Three ways out, none
    // of which leaves a process behind:
    //   - the shell dies (kill -9 included): the pipe closes, cat sees EOF,
    //     the sentinel kills the stream, `wait` returns;
    //   - the stream dies on its own: `wait` returns, the sentinel is told to
    //     kill its cat, the wrapper exits and Quickshell restarts it;
    //   - Quickshell stops the Process (reload): SIGTERM, the trap kills both.
    // A `kill -0 $QS_PID; sleep 5` loop would do the same with a spawn every
    // 5 s; this does it with none.
    readonly property string __streamScript: `
exec 3<&0
media-control stream --no-diff --no-artwork --debounce=250 & STREAM=$!
( trap 'kill $CAT 2>/dev/null; exit' TERM; cat <&3 >/dev/null & CAT=$!; wait $CAT; kill $STREAM 2>/dev/null ) & SENTINEL=$!
trap 'kill $STREAM $SENTINEL 2>/dev/null; exit 143' TERM INT HUP
wait $STREAM
kill $SENTINEL 2>/dev/null
`

    // Long-lived: one JSON object per line. Artwork is stripped because it
    // dwarfs the rest of the payload and this shim cannot surface it anyway.
    Process {
        id: stream

        running: true
        // The wrapper's sentinel reads this pipe; closed, it would kill the
        // stream on the spot.
        stdinEnabled: true
        command: ["sh", "-c", root.__streamScript]

        stdout: SplitParser {
            onRead: line => {
                if (!line.trim().startsWith("{"))
                    return;
                root.__restartMs = 3000;
                try {
                    root.__apply(JSON.parse(line), true);
                } catch (e) {
                // A truncated frame is not worth surfacing; another lands in 250ms.
                }
            }
        }

        onExited: {
            streamRestart.start();
            // A stream that dies before producing a frame (media-control broken
            // by a macOS update) must not be respawned every 3 s forever.
            root.__restartMs = Math.min(root.__restartMs * 2, 60000);
        }
    }

    property int __restartMs: 3000

    Timer {
        id: streamRestart

        interval: root.__restartMs
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
                } catch (e) {
                    return;
                }
                // __apply only fetches artwork when the track changed, and
                // whatever is already playing at startup has not changed.
                if (root.__players.length > 0)
                    root.__fetchArtwork();
            }
        }
    }

    Process {
        id: nameProc

        property string bundle: ""

        stdout: StdioCollector {
            onStreamFinished: {
                // `"LSDisplayName"="Spotify"`; empty when the app is not running.
                const m = text.match(/"LSDisplayName"="(.+)"/);
                const names = root.__names;
                names[nameProc.bundle] = m ? m[1] : root.__identityFor(nameProc.bundle);
                root.__names = names;
                if (root.__player.bundleId === nameProc.bundle)
                    root.__player.identity = names[nameProc.bundle];
            }
        }
    }
}
