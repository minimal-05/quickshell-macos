// Acceptance probe for the Pipewire shim on its CoreAudio backend. Asserts
// the shape end-4's Audio service reads and exposes the default sink/source
// state over IPC so tests/native-audio.sh can compare it with osascript and
// SwitchAudioSource, in both directions.
//   bin/qs-test tests/_probe_audio.qml -- audio check == ok
//   bin/qs-test tests/_probe_audio.qml -- audio volume       (compare to osascript)
// Only the public Pipewire API is used, so the same probe runs against the
// old process-spawning shim for a before/after qs-perf comparison.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

ShellRoot {
    id: root

    // Count HAL-driven changes landing on the default sink, to prove the
    // listener path (not a poll) is what moved the value.
    property int sinkVolumeEvents: 0
    property int sinkMuteEvents: 0

    Component.onCompleted: void Pipewire.defaultAudioSink

    Connections {
        target: Pipewire.defaultAudioSink?.audio ?? null

        function onVolumeChanged(): void {
            root.sinkVolumeEvents++;
        }

        function onMutedChanged(): void {
            root.sinkMuteEvents++;
        }
    }

    IpcHandler {
        target: "audio"

        function check(): string {
            if (!Pipewire.ready)
                return "not-ready";
            const sink = Pipewire.defaultAudioSink;
            const source = Pipewire.defaultAudioSource;
            if (!sink)
                return "no-sink";
            if (!sink.ready || !sink.isSink || sink.isStream || sink.type !== PwNodeType.AudioSink)
                return "bad-sink-shape";
            if (!(sink.audio.volume >= 0 && sink.audio.volume <= 1))
                return "bad-volume " + sink.audio.volume;
            if (sink.audio.channels.length < 1 || sink.audio.volumes.length !== sink.audio.channels.length)
                return "bad-channels";
            if (!sink.description || !sink.nickname || !sink.name)
                return "bad-names";
            if (sink.properties["node.description"] !== sink.description)
                return "bad-properties";
            if (source && (source.isSink || source.type !== PwNodeType.AudioSource))
                return "bad-source-shape";
            const nodes = Pipewire.nodes.values;
            if (!nodes.includes(sink) || (source && !nodes.includes(source)))
                return "defaults-not-in-nodes";
            if (nodes.some(n => n.isStream || !n.audio))
                return "bad-node";
            if (Pipewire.preferredDefaultAudioSink !== sink)
                return "preferred-not-mirrored";
            if (Pipewire.links.values.length !== 0 || Pipewire.linkGroups.values.length !== 0)
                return "links-not-empty";
            return "ok";
        }

        function sink(): string {
            return Pipewire.defaultAudioSink?.description ?? "";
        }

        function source(): string {
            return Pipewire.defaultAudioSource?.description ?? "";
        }

        function sinks(): string {
            return Pipewire.nodes.values.filter(n => n.isSink).map(n => n.description).join("\n");
        }

        function sources(): string {
            return Pipewire.nodes.values.filter(n => !n.isSink).map(n => n.description).join("\n");
        }

        function volume(): string {
            return String(Math.round((Pipewire.defaultAudioSink?.audio.volume ?? 0) * 100));
        }

        function muted(): string {
            return String(Pipewire.defaultAudioSink?.audio.muted ?? false);
        }

        function inputVolume(): string {
            return String(Math.round((Pipewire.defaultAudioSource?.audio.volume ?? 0) * 100));
        }

        function inputMuted(): string {
            return String(Pipewire.defaultAudioSource?.audio.muted ?? false);
        }

        // Writes go through the public node API, exactly as the shell does.
        function setVolume(pct: int): string {
            Pipewire.defaultAudioSink.audio.volume = pct / 100;
            return this.volume();
        }

        function setMuted(muted: bool): string {
            Pipewire.defaultAudioSink.audio.muted = muted;
            return this.muted();
        }

        function setInputVolume(pct: int): string {
            Pipewire.defaultAudioSource.audio.volume = pct / 100;
            return this.inputVolume();
        }

        function events(): string {
            return root.sinkVolumeEvents + " " + root.sinkMuteEvents;
        }

        function dump(): string {
            const out = {
                ready: Pipewire.ready
            };
            out.nodes = Pipewire.nodes.values.map(n => ({
                        id: n.id,
                        name: n.name,
                        description: n.description,
                        isSink: n.isSink,
                        type: PwNodeType.toString(n.type),
                        volume: n.audio.volume,
                        muted: n.audio.muted,
                        channels: n.audio.channels.map(c => PwAudioChannel.toString(c)),
                        properties: n.properties
                    }));
            out.sink = Pipewire.defaultAudioSink?.id ?? null;
            out.source = Pipewire.defaultAudioSource?.id ?? null;
            return JSON.stringify(out);
        }
    }
}
