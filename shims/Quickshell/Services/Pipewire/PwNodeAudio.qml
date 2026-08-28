import QtQuick

// Quickshell.Services.Pipewire.PwNodeAudio - macOS compatibility shim.
//
// REAL, for the node that is currently the default output or input device:
//   - `volume` (0.0-1.0 REAL, as upstream; macOS reports 0-100 INT and the
//     owning Pipewire singleton does the /100 and *100 conversion)
//   - `muted` for the default *output* (AppleScript `output muted`)
//   - `volumes`, kept in sync with `volume` across `channels`
// INERT / degraded:
//   - `muted` on the default *input*: AppleScript has no input mute, so the
//     Pipewire singleton emulates it by parking input volume at 0.
//   - every non-default device node: CoreAudio will not hand out another
//     device's scalar volume through any of the CLI tools available here, so
//     those nodes read 0 / false and writes to them are dropped.
//
// Writes are reported to the owner through volumeRequested/mutedRequested
// rather than performed here, so that this file stays a dumb value holder.
// `__push` is how the owner writes back polled values without those writes
// bouncing straight back out as a new request.
QtObject {
    id: root

    property bool muted: false
    // 0.0 - 1.0 (values above 1.0 are accepted by bindings but clamped when
    // handed to macOS, which has no software boost).
    property real volume: 0
    property var channels: [PwAudioChannel.FrontLeft, PwAudioChannel.FrontRight]
    property var volumes: [0, 0]

    // Emitted when something *outside* this object writes a value, i.e. a
    // real user action that should reach the hardware.
    signal volumeRequested(real volume)
    signal mutedRequested(bool muted)

    // True while the owner is pushing polled state in; suppresses the
    // requested() signals so polling never turns into a write loop.
    property bool __internal: false

    onVolumeChanged: {
        if (root.__internal)
            return;

        root.__internal = true;
        root.volumes = root.channels.map(() => root.volume);
        root.__internal = false;

        root.volumeRequested(root.volume);
    }

    onMutedChanged: {
        if (root.__internal)
            return;
        root.mutedRequested(root.muted);
    }

    onVolumesChanged: {
        if (root.__internal)
            return;

        const vs = root.volumes;
        if (!vs || vs.length === 0)
            return;

        let sum = 0;
        for (const v of vs)
            sum += v;

        // Reassigning volume re-enters onVolumeChanged, which resyncs volumes
        // and emits the request exactly once.
        root.volume = sum / vs.length;
    }

    // Owner-side setter: update without emitting a write request.
    function __push(volume: real, muted: bool): void {
        root.__internal = true;
        root.volume = volume;
        root.volumes = root.channels.map(() => volume);
        root.muted = muted;
        root.__internal = false;
    }
}
