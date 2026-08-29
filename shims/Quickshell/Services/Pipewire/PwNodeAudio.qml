import QtQuick

// Quickshell.Services.Pipewire.PwNodeAudio - macOS compatibility shim.
//
// REAL, on every node (the HAL hands out any device's controls, not only the
// default's):
//   - `volume` (0.0-1.0 REAL, as upstream; the CoreAudio scalar is already
//     in that range, so no conversion happens anywhere)
//   - `muted`
//   - `volumes`, kept in sync with `volume` across `channels`
// DEGRADED:
//   - a device without a software volume (HDMI, AirPlay, continuity mics)
//     reads 0 / false and drops writes.
//   - `muted` on a device without a hardware mute control is emulated by
//     the singleton (volume parked at 0, restored on unmute).
//
// Writes are reported to the owner through volumeRequested/mutedRequested
// rather than performed here, so that this file stays a dumb value holder.
// `__push` is how the owner writes HAL values in without those writes
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

    // True while the owner is pushing HAL state in; suppresses the
    // requested() signals so a readback never turns into a write loop.
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
