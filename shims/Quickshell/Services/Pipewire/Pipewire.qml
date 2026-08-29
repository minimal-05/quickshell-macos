pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Cocoa

// Quickshell.Services.Pipewire.Pipewire - macOS compatibility shim.
//
// Backed by the in-process Quickshell.Cocoa.CoreAudio singleton, which sits on
// the CoreAudio HAL's property listeners. Nothing here polls and nothing
// spawns: a volume key, a headset pairing or a Sound-settings change arrives
// as a signal and is on the node within a millisecond.
//
// WHAT IS REAL
//   - `nodes`: one PwNode per direction of every CoreAudio device - a sink
//     for each device with output streams, a source for each with input
//     streams (a Bluetooth headset is both). Identity is stable for as long
//     as the device stays plugged in.
//   - `defaultAudioSink` / `defaultAudioSource`: the HAL's default output and
//     input devices, updated the moment they change.
//   - `PwNode.audio.volume` / `.muted` on EVERY node, read and write, not just
//     the defaults: the HAL hands out any device's controls.
//   - `preferredDefaultAudioSink` / `preferredDefaultAudioSource`: writing a
//     node switches the system default; the property mirrors the confirmed
//     default afterwards, as upstream's preferred-default metadata does.
//   - `ready`: true once the first enumeration is done, which is synchronous.
//
// WHAT IS INERT
//   - `links` / `linkGroups`: always empty. CoreAudio exposes no routing
//     graph, so Privacy.qml's mic/screen-share indicators stay off.
//   - No per-application stream nodes: every node has `isStream === false`, so
//     an application mixer renders empty rather than wrong. ponytail: the HAL
//     has kAudioHardwarePropertyProcessObjectList (macOS 14.2+) with bundle id
//     and running state per process, which would give read-only stream nodes;
//     per-app volume still needs a process tap. Not wired.
//   - Devices with no software volume (HDMI, AirPlay receivers, the iPhone
//     continuity mic) report volume 0 / muted false and drop writes; the
//     CoreAudioDevice `*VolumeSupported` flags say which.
//   - Input mute on a device without a hardware mute control is emulated by
//     parking the input volume at 0 (see coreaudio.hpp). Apple's built-in
//     microphone has a real one.
Singleton {
    id: root

    // ---- upstream API surface -------------------------------------------

    readonly property bool ready: root.__ready

    property PwNode defaultAudioSink: null
    property PwNode defaultAudioSource: null

    property PwNode preferredDefaultAudioSink: null
    property PwNode preferredDefaultAudioSource: null

    readonly property ScriptModel nodes: ScriptModel {
        values: root.__nodes
    }

    readonly property ScriptModel links: ScriptModel {
        values: []
    }

    readonly property ScriptModel linkGroups: ScriptModel {
        values: []
    }

    // ---- shim internals --------------------------------------------------

    property bool __ready: false
    property var __nodes: []
    property var __nodesByKey: ({})

    // Set while we mirror a confirmed default back into the preferred*
    // properties, so that mirroring does not read as a user switch request.
    property bool __mirroringPreferred: false

    Component {
        id: nodeComponent

        PwNode {}
    }

    function __key(device, isSink: bool): string {
        return (isSink ? "sink:" : "source:") + device.id;
    }

    // Upstream reports the SPA channel map; CoreAudio only gives a count.
    function __channels(count: int): var {
        if (count === 1)
            return [PwAudioChannel.Mono];
        if (count === 2)
            return [PwAudioChannel.FrontLeft, PwAudioChannel.FrontRight];
        return Array.from({
            length: count
        }, (_, i) => PwAudioChannel.AuxRangeStart + i);
    }

    function __properties(device, isSink: bool): var {
        return {
            "node.name": device.uid,
            "node.description": device.name,
            "node.nick": device.name,
            "device.description": device.name,
            "device.api": "coreaudio",
            "device.bus": device.transport,
            "media.class": isSink ? "Audio/Sink" : "Audio/Source"
        };
    }

    function __makeNode(device, isSink: bool): PwNode {
        const node = nodeComponent.createObject(root, {
            name: device.uid,
            description: device.name,
            nickname: device.name,
            isSink: isSink,
            isStream: false,
            type: isSink ? PwNodeType.AudioSink : PwNodeType.AudioSource,
            ready: true
        });
        if (!node)
            return null;

        // The AudioObjectID, so `id` means the same thing as upstream's
        // pipewire object id. A duplex device owns both a sink and a source
        // node; the source side is offset so the two ids never collide.
        node.__id = isSink ? device.id : device.id + 0x10000000;
        node.__device = device;
        node.properties = root.__properties(device, isSink);
        node.audio.channels = root.__channels(isSink ? device.outputChannels : device.inputChannels);

        // HAL -> node. `__push` writes without bouncing back out as a request.
        const push = () => {
            if (isSink)
                node.audio.__push(device.outputVolume, device.outputMuted);
            else
                node.audio.__push(device.inputVolume, device.inputMuted);
        };
        push();
        if (isSink)
            device.outputChanged.connect(push);
        else
            device.inputChanged.connect(push);

        device.nameChanged.connect(() => {
            node.description = device.name;
            node.nickname = device.name;
            node.properties = root.__properties(device, isSink);
        });

        // Node -> HAL. The setter re-reads what the hardware settled on, and
        // the push after it corrects an optimistic write the device dropped
        // (no volume control) back to the real value.
        node.audio.volumeRequested.connect(volume => {
            if (isSink)
                device.outputVolume = volume;
            else
                device.inputVolume = volume;
            push();
        });
        node.audio.mutedRequested.connect(muted => {
            if (isSink)
                device.outputMuted = muted;
            else
                device.inputMuted = muted;
            push();
        });

        return node;
    }

    function __rebuildNodes(): void {
        const kept = ({});
        const result = [];

        const take = (device, isSink) => {
            const key = root.__key(device, isSink);
            let node = root.__nodesByKey[key];
            if (!node)
                node = root.__makeNode(device, isSink);
            if (!node)
                return;
            kept[key] = node;
            result.push(node);
        };

        for (const device of CoreAudio.devices) {
            if (device.outputChannels > 0)
                take(device, true);
            if (device.inputChannels > 0)
                take(device, false);
        }

        root.__nodes = result;

        // Resolve the defaults against the new list before dropping anything,
        // so the sink/source properties never briefly point at a dead object.
        const stale = [];
        for (const key in root.__nodesByKey) {
            if (kept[key] === undefined)
                stale.push(root.__nodesByKey[key]);
        }
        root.__nodesByKey = kept;
        root.__resolveDefaults();

        for (const node of stale)
            node.destroy();
    }

    function __resolveDefaults(): void {
        const output = CoreAudio.defaultOutput;
        const input = CoreAudio.defaultInput;
        const newSink = output ? (root.__nodesByKey[root.__key(output, true)] ?? null) : null;
        const newSource = input ? (root.__nodesByKey[root.__key(input, false)] ?? null) : null;

        root.defaultAudioSink = newSink;
        root.defaultAudioSource = newSource;

        root.__mirroringPreferred = true;
        root.preferredDefaultAudioSink = newSink;
        root.preferredDefaultAudioSource = newSource;
        root.__mirroringPreferred = false;
    }

    Connections {
        target: CoreAudio

        function onDevicesChanged(): void {
            root.__rebuildNodes();
        }

        function onDefaultOutputChanged(): void {
            root.__resolveDefaults();
        }

        function onDefaultInputChanged(): void {
            root.__resolveDefaults();
        }
    }

    onPreferredDefaultAudioSinkChanged: {
        if (root.__mirroringPreferred)
            return;
        const node = root.preferredDefaultAudioSink;
        if (!node || node === root.defaultAudioSink || !node.__device)
            return;
        CoreAudio.defaultOutput = node.__device;
    }

    onPreferredDefaultAudioSourceChanged: {
        if (root.__mirroringPreferred)
            return;
        const node = root.preferredDefaultAudioSource;
        if (!node || node === root.defaultAudioSource || !node.__device)
            return;
        CoreAudio.defaultInput = node.__device;
    }

    Component.onCompleted: {
        root.__rebuildNodes();
        root.__ready = true;
    }
}
