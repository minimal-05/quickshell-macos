import QtQuick
import Quickshell.Io

// Quickshell.Services.Mpris.MprisPlayer - macOS compatibility shim.
//
// Backed by `media-control`, which reaches Apple's MediaRemote framework. All
// state is pushed in by the Mpris singleton; all commands are executed here.
//
// WHAT IS REAL
//   - trackTitle / trackArtist / trackAlbum / metadata / uniqueId
//   - isPlaying / playbackState (Playing or Paused; see MprisPlaybackState)
//   - position (interpolated between MediaRemote updates so it advances
//     smoothly) and length, both in seconds with sub-second precision
//   - identity, derived from the owning app's bundle identifier
//   - play() / pause() / togglePlaying() / stop() / next() / previous()
//   - seeking: writing `position` and calling seek() run `media-control seek`
//   - raise() opens the owning app; quit() quits it (both via its bundle id)
//
// WHAT IS INERT OR DEGRADED
//   - trackArtUrl is always "". media-control can emit artwork, but only as
//     base64 bytes on a stream we deliberately run with --no-artwork, and a
//     pure-QML shim has nowhere to put a decoded image that Image can load.
//     Consumers already guard this with `|| fallback`.
//   - trackAlbumArtist is always "" - MediaRemote has no such field.
//   - volume is fixed at 1.0 and volumeSupported is false. MediaRemote exposes
//     no per-player volume; system volume lives in the Pipewire shim instead.
//   - loopState / shuffle are write-through only (`media-control repeat` and
//     `shuffle` exist, reading them back does not), so loopSupported and
//     shuffleSupported are false and consumers will hide those controls.
//   - rate / minRate / maxRate are pinned to 1.0. `media-control speed` exists
//     but nothing reads the current speed back, and upstream treats
//     min == max == 1 as "no rate control", which is the honest signal.
//   - fullscreen / canSetFullscreen are false; desktopEntry carries the macOS
//     bundle identifier, which is the closest analogue to a .desktop name but
//     will not resolve against a freedesktop icon theme.
//   - dbusName is synthesised as org.mpris.MediaPlayer2.<slug>. There is no
//     D-Bus here; it exists because configs filter duplicate players on it.
QtObject {
    id: root

    // ---- identity --------------------------------------------------------

    property string identity: ""
    property string desktopEntry: ""
    property string dbusName: ""

    // The macOS bundle identifier that owns the now-playing session.
    property string bundleId: ""

    // ---- track -----------------------------------------------------------

    property var metadata: ({})
    property int uniqueId: 0
    property string trackTitle: ""
    property string trackArtist: ""
    readonly property string trackArtists: root.trackArtist // deprecated upstream
    property string trackAlbum: ""
    property string trackAlbumArtist: ""
    property string trackArtUrl: ""

    signal trackChanged
    signal postTrackChanged

    // ---- playback --------------------------------------------------------

    // Both are read/write, as upstream: assigning either is equivalent to
    // calling play()/pause()/stop(). __setState is the internal path that
    // updates them together without re-triggering a command.
    property int playbackState: MprisPlaybackState.Stopped
    property bool isPlaying: false

    property real position: 0
    property bool positionSupported: true
    property real length: 0
    property bool lengthSupported: true

    property real volume: 1.0
    readonly property bool volumeSupported: false

    property int loopState: MprisLoopState.None
    readonly property bool loopSupported: false

    property bool shuffle: false
    readonly property bool shuffleSupported: false

    property real rate: 1.0
    readonly property real minRate: 1.0
    readonly property real maxRate: 1.0

    property bool fullscreen: false
    readonly property bool canSetFullscreen: false

    readonly property var supportedUriSchemes: []
    readonly property var supportedMimeTypes: []

    // ---- capabilities ----------------------------------------------------

    readonly property bool canControl: true
    readonly property bool canPlay: true
    readonly property bool canPause: true
    readonly property bool canTogglePlaying: true
    readonly property bool canGoNext: true
    readonly property bool canGoPrevious: true
    readonly property bool canSeek: root.length > 0
    readonly property bool canQuit: root.bundleId.length > 0
    readonly property bool canRaise: root.bundleId.length > 0

    // ---- methods ---------------------------------------------------------

    function play(): void {
        root.__ctl.exec(["media-control", "play"]);
        root.__optimistic(MprisPlaybackState.Playing);
    }

    function pause(): void {
        root.__ctl.exec(["media-control", "pause"]);
        root.__optimistic(MprisPlaybackState.Paused);
    }

    function stop(): void {
        root.__ctl.exec(["media-control", "stop"]);
        root.__optimistic(MprisPlaybackState.Paused);
    }

    function togglePlaying(): void {
        root.__ctl.exec(["media-control", "toggle-play-pause"]);
        root.__optimistic(root.isPlaying ? MprisPlaybackState.Paused : MprisPlaybackState.Playing);
    }

    function next(): void {
        root.__ctl.exec(["media-control", "next-track"]);
    }

    function previous(): void {
        root.__ctl.exec(["media-control", "previous-track"]);
    }

    function seek(offset: real): void {
        root.__seekTo(root.position + offset);
    }

    function raise(): void {
        if (root.bundleId.length > 0)
            root.__ctl.exec(["open", "-b", root.bundleId]);
    }

    function quit(): void {
        if (root.bundleId.length > 0)
            root.__ctl.exec(["osascript", "-e", `quit app id "${root.bundleId}"`]);
    }

    function openUri(uri: string): void {
        // No player here advertises a uri scheme, so this is best effort:
        // hand the uri to LaunchServices and let macOS decide.
        if (uri.length > 0)
            root.__ctl.exec(["open", uri]);
    }

    // ---- internals -------------------------------------------------------

    // QtObject has no default property, so helper objects hang off named
    // properties rather than being declared as children.
    property Process __ctl: Process {}

    // Seconds of `position` at the moment __base was last stamped, and the
    // wall clock (ms) of that stamp. Between MediaRemote updates the ticker
    // interpolates from these so the position advances instead of freezing.
    property real __baseElapsed: 0
    property real __baseTime: 0
    property bool __internalPos: false

    // The last value this shim wrote to `position`. A bare positionChanged()
    // emission arrives with `position` still equal to it; a write does not.
    property real __lastPos: 0

    // Advance `position` by interpolating from the last MediaRemote stamp.
    function __tick(): void {
        if (!root.isPlaying || root.length <= 0)
            return;
        const next = root.__baseElapsed + (Date.now() - root.__baseTime) / 1000;
        root.__setPosition(Math.min(next, root.length));
    }

    property Timer __ticker: Timer {
        interval: 1000
        repeat: true
        running: root.isPlaying && root.length > 0
        onTriggered: root.__tick()
    }

    onPositionChanged: {
        if (root.__internalPos)
            return;

        // Upstream's `position` is re-read on demand, so configs emit
        // positionChanged() on a timer purely to make bindings refresh --
        // end-4 does exactly that, labelled "Force update for revision".
        // Here `position` is a plain property, so that hint reaches us as this
        // signal with the value unchanged, while a real write (the seek
        // slider) always changes it. Treating the hint as a seek re-sent the
        // last interpolated sample to `media-control seek` on every tick,
        // dragging playback back by up to the ticker interval each time.
        // Refresh the interpolation instead; only a write is a seek.
        if (root.position === root.__lastPos) {
            root.__tick();
            return;
        }

        root.__seekTo(root.position);
    }

    property bool __internalState: false

    onPlaybackStateChanged: {
        if (root.__internalState)
            return;

        const state = root.playbackState;
        root.__setState(state);

        if (state === MprisPlaybackState.Playing)
            root.play();
        else if (state === MprisPlaybackState.Paused)
            root.pause();
        else
            root.stop();
    }

    onIsPlayingChanged: {
        if (root.__internalState)
            return;

        const playing = root.isPlaying;
        root.__setState(playing ? MprisPlaybackState.Playing : MprisPlaybackState.Paused);

        if (playing)
            root.play();
        else
            root.pause();
    }

    function __setState(state: int): void {
        root.__internalState = true;
        root.playbackState = state;
        root.isPlaying = state === MprisPlaybackState.Playing;
        root.__internalState = false;
    }

    onLoopStateChanged: {
        const modes = ["off", "track", "playlist"];
        const mode = modes[root.loopState] ?? "off";
        root.__ctl.exec(["media-control", "repeat", mode]);
    }

    onShuffleChanged: {
        root.__ctl.exec(["media-control", "shuffle", root.shuffle ? "tracks" : "off"]);
    }

    function __setPosition(seconds: real): void {
        root.__internalPos = true;
        root.position = seconds;
        root.__lastPos = seconds;
        root.__internalPos = false;
    }

    function __seekTo(seconds: real): void {
        const target = Math.max(0, root.length > 0 ? Math.min(seconds, root.length) : seconds);
        root.__rebase(target);
        root.__setPosition(target);
        root.__ctl.exec(["media-control", "seek", `${target.toFixed(3)}`]);
    }

    // Restamp the interpolation origin. Called by the Mpris singleton whenever
    // a fresh elapsedTime arrives, and locally after a seek.
    function __rebase(elapsed: real): void {
        root.__baseElapsed = elapsed;
        root.__baseTime = Date.now();
    }

    // Assume a transport command took effect, so the UI flips immediately
    // rather than waiting for the next MediaRemote frame.
    function __optimistic(state: int): void {
        root.__rebase(root.position);
        root.__setState(state);
    }
}
