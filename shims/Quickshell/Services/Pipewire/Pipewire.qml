pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Quickshell.Services.Pipewire.Pipewire - macOS compatibility shim.
//
// WHAT IS REAL
//   - `defaultAudioSink` / `defaultAudioSource`: the current CoreAudio default
//     output and input, from `SwitchAudioSource -c -t output|input`.
//   - `defaultAudioSink.audio.volume` / `.muted`: live, read AND write, via
//     AppleScript `get volume settings` / `set volume output volume|muted`.
//     Quickshell's volume is a 0.0-1.0 REAL; macOS wants a 0-100 INT, so this
//     file is the only place the /100 and *100 conversion happens.
//   - `defaultAudioSource.audio.volume`: live read/write (`input volume`).
//   - `nodes`: one PwNode per CoreAudio output and input device, from
//     `SwitchAudioSource -a -t output|input`. Enough for a device picker.
//   - `preferredDefaultAudioSink` / `preferredDefaultAudioSource`: writing a
//     node actually switches the system default device.
//   - `ready`: true once the first volume read and device enumeration land.
//
// WHAT IS INERT (see the module's `gaps`)
//   - `links` / `linkGroups`: always empty. CoreAudio exposes no routing graph.
//   - No per-application stream nodes: every node has `isStream === false`, so
//     an application volume mixer renders empty rather than wrong. Reaching
//     per-app volume on macOS needs a CoreAudio HAL plugin (BlackHole-style),
//     which is well outside a pure-QML shim.
//   - Non-default device nodes report volume 0 / muted false: no CLI on this
//     machine will read another device's scalar volume. Only the default
//     device's audio is live.
//   - `defaultAudioSource.audio.muted` is emulated. AppleScript has no input
//     mute, so "muted" means input volume parked at 0, and unmuting restores
//     the last nonzero level.
//
// Polling, not events: nothing on macOS pushes volume changes to us, so a
// timer reads back. The intervals are slow enough that dragging a slider does
// not fight the poller, and writes update the property optimistically first.
Singleton {
    id: root

    // ---- upstream API surface -------------------------------------------

    readonly property bool ready: root.__haveVolume && root.__haveDevices

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

    property var __nodes: []
    property var __nodesByKey: ({})
    property int __nextId: 1

    property bool __haveVolume: false
    property bool __haveDevices: false

    property string __outputDeviceName: ""
    property string __inputDeviceName: ""
    property var __outputDeviceNames: []
    property var __inputDeviceNames: []

    // Last nonzero input volume, so emulated input unmute has something to
    // restore to.
    property real __inputRestore: 0.5

    // Set while we mirror a resolved default back into the preferred*
    // properties, so that mirroring does not read as a user switch request.
    property bool __mirroringPreferred: false

    Component {
        id: nodeComponent

        PwNode {}
    }

    function __key(name: string, isSink: bool): string {
        return (isSink ? "sink:" : "source:") + name;
    }

    function __rebuildNodes(): void {
        const kept = ({});
        const result = [];

        function take(name, isSink) {
            const key = root.__key(name, isSink);
            let node = root.__nodesByKey[key];
            if (!node) {
                node = nodeComponent.createObject(root, {
                    name: name,
                    description: name,
                    nickname: name,
                    isSink: isSink,
                    isStream: false,
                    type: isSink ? PwNodeType.AudioSink : PwNodeType.AudioSource,
                    ready: true
                });
                if (!node)
                    return;
                node.__id = root.__nextId++;
                node.properties = {
                    "node.name": name,
                    "node.description": name,
                    "device.description": name
                };
                if (!isSink)
                    node.audio.channels = [PwAudioChannel.Mono];
                node.audio.volumeRequested.connect(v => root.__onVolumeRequested(node, v));
                node.audio.mutedRequested.connect(m => root.__onMutedRequested(node, m));
            }
            kept[key] = node;
            result.push(node);
        }

        for (const name of root.__outputDeviceNames)
            take(name, true);
        for (const name of root.__inputDeviceNames)
            take(name, false);

        // Resolve the defaults against the new list before dropping anything,
        // so the sink/source properties never briefly point at a dead object.
        const newSink = kept[root.__key(root.__outputDeviceName, true)] ?? null;
        const newSource = kept[root.__key(root.__inputDeviceName, false)] ?? null;

        const oldSink = root.defaultAudioSink;
        const oldSource = root.defaultAudioSource;

        root.__nodes = result;
        root.defaultAudioSink = newSink;
        root.defaultAudioSource = newSource;

        root.__mirroringPreferred = true;
        root.preferredDefaultAudioSink = newSink;
        root.preferredDefaultAudioSource = newSource;
        root.__mirroringPreferred = false;

        for (const key in root.__nodesByKey) {
            if (kept[key] !== undefined)
                continue;
            const stale = root.__nodesByKey[key];
            if (stale && stale !== oldSink && stale !== oldSource)
                stale.destroy();
        }
        root.__nodesByKey = kept;

        // A device that vanished may have been the default; push the current
        // readings onto whatever took its place.
        root.__applyReadings();
    }

    // Push the last polled macOS readings onto the two live nodes.
    property real __outputVolume: 0
    property bool __outputMuted: false
    property real __inputVolume: 0

    function __applyReadings(): void {
        if (root.defaultAudioSink)
            root.defaultAudioSink.audio.__push(root.__outputVolume, root.__outputMuted);
        if (root.defaultAudioSource)
            root.defaultAudioSource.audio.__push(root.__inputVolume, root.__inputVolume <= 0);
    }

    // ---- write paths -----------------------------------------------------

    // An osascript spawn costs ~90ms, which is slower than a held volume key
    // repeats or a slider drags. Firing one per request made writes queue up
    // behind each other and the poller then snapped the value back, so the
    // latest requested value is parked here and pushed on a short timer.
    property int __pendingOutput: -1
    property int __pendingInput: -1
    // When we last asked macOS to change something, so a poll that was already
    // in flight cannot push the pre-change value back over it.
    property double __lastWrite: 0

    function __onVolumeRequested(node, volume): void {
        root.__lastWrite = Date.now();
        // Only the current default device is writable; see the header comment.
        if (node === root.defaultAudioSink) {
            const pct = Math.max(0, Math.min(100, Math.round(volume * 100)));
            root.__outputVolume = pct / 100;
            root.__pendingOutput = pct;
            volumeFlush.restart();
        } else if (node === root.defaultAudioSource) {
            const pct = Math.max(0, Math.min(100, Math.round(volume * 100)));
            root.__inputVolume = pct / 100;
            if (pct > 0)
                root.__inputRestore = pct / 100;
            root.__pendingInput = pct;
            volumeFlush.restart();
        }
    }

    Timer {
        id: volumeFlush

        // Repeating, because a write must not be handed to a Process that is
        // still running the previous one -- a held key repeats faster than
        // osascript returns, and those writes were being lost. Keep the value
        // parked and try again next tick instead, then stop once it is out.
        interval: 40
        repeat: true
        onTriggered: {
            if (root.__pendingOutput < 0 && root.__pendingInput < 0) {
                volumeFlush.stop();
                return;
            }
            if (root.__pendingOutput >= 0 && !volumeSetter.running) {
                volumeSetter.exec(["osascript", "-e", `set volume output volume ${root.__pendingOutput}`]);
                root.__pendingOutput = -1;
            }
            if (root.__pendingInput >= 0 && !inputSetter.running) {
                inputSetter.exec(["osascript", "-e", `set volume input volume ${root.__pendingInput}`]);
                root.__pendingInput = -1;
            }
        }
    }

    function __onMutedRequested(node, muted): void {
        root.__lastWrite = Date.now();
        if (node === root.defaultAudioSink) {
            root.__outputMuted = muted;
            muteSetter.exec(["osascript", "-e", `set volume output muted ${muted ? "true" : "false"}`]);
        } else if (node === root.defaultAudioSource) {
            // Emulated: AppleScript has no input mute.
            if (muted) {
                if (root.__inputVolume > 0)
                    root.__inputRestore = root.__inputVolume;
                root.__inputVolume = 0;
                muteSetter.exec(["osascript", "-e", "set volume input volume 0"]);
            } else {
                const pct = Math.max(1, Math.round(root.__inputRestore * 100));
                root.__inputVolume = pct / 100;
                muteSetter.exec(["osascript", "-e", `set volume input volume ${pct}`]);
            }
        }
    }

    onPreferredDefaultAudioSinkChanged: {
        if (root.__mirroringPreferred)
            return;
        const node = root.preferredDefaultAudioSink;
        if (!node || node === root.defaultAudioSink)
            return;
        deviceSwitcher.exec(["SwitchAudioSource", "-t", "output", "-s", node.name]);
        root.__refreshDevices();
    }

    onPreferredDefaultAudioSourceChanged: {
        if (root.__mirroringPreferred)
            return;
        const node = root.preferredDefaultAudioSource;
        if (!node || node === root.defaultAudioSource)
            return;
        deviceSwitcher.exec(["SwitchAudioSource", "-t", "input", "-s", node.name]);
        root.__refreshDevices();
    }

    function __refreshDevices(): void {
        currentOutputProbe.running = true;
        currentInputProbe.running = true;
        outputListProbe.running = true;
        inputListProbe.running = true;
    }

    // ---- processes -------------------------------------------------------

    Process {
        id: volumeSetter
    }

    // Separate from volumeSetter so an output and an input write in the same
    // flush do not cancel each other.
    Process {
        id: inputSetter
    }

    Process {
        id: muteSetter
    }

    Process {
        id: deviceSwitcher
    }

    // One AppleScript call for all three scalar readings.
    Process {
        id: volumeProbe

        running: true
        command: ["osascript", "-e", "set s to (get volume settings)\nreturn (output volume of s as string) & \",\" & (output muted of s as string) & \",\" & (input volume of s as string)"]

        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.trim().split(",");
                if (parts.length < 3)
                    return;

                const outVol = parseInt(parts[0], 10);
                const inVol = parseInt(parts[2], 10);
                if (isNaN(outVol) || isNaN(inVol))
                    return;

                // A read that overlapped our own write returns the old value and
                // would undo it. Keep what we asked for until it settles.
                if (root.__haveVolume && Date.now() - root.__lastWrite < 1200)
                    return;

                root.__outputVolume = outVol / 100;
                root.__outputMuted = parts[1].trim() === "true";
                root.__inputVolume = inVol / 100;
                if (inVol > 0)
                    root.__inputRestore = inVol / 100;

                root.__haveVolume = true;
                root.__applyReadings();
            }
        }
    }

    Process {
        id: currentOutputProbe

        running: true
        command: ["SwitchAudioSource", "-c", "-t", "output"]

        stdout: StdioCollector {
            onStreamFinished: {
                const name = text.trim();
                if (!name || name === root.__outputDeviceName)
                    return;
                root.__outputDeviceName = name;
                root.__rebuildNodes();
            }
        }
    }

    Process {
        id: currentInputProbe

        running: true
        command: ["SwitchAudioSource", "-c", "-t", "input"]

        stdout: StdioCollector {
            onStreamFinished: {
                const name = text.trim();
                if (!name || name === root.__inputDeviceName)
                    return;
                root.__inputDeviceName = name;
                root.__rebuildNodes();
            }
        }
    }

    Process {
        id: outputListProbe

        running: true
        command: ["SwitchAudioSource", "-a", "-t", "output"]

        stdout: StdioCollector {
            onStreamFinished: {
                const names = text.trim().split("\n").map(l => l.trim()).filter(l => l.length > 0);
                if (names.join(" ") === root.__outputDeviceNames.join(" "))
                    return;
                root.__outputDeviceNames = names;
                root.__haveDevices = true;
                root.__rebuildNodes();
            }
        }
    }

    Process {
        id: inputListProbe

        running: true
        command: ["SwitchAudioSource", "-a", "-t", "input"]

        stdout: StdioCollector {
            onStreamFinished: {
                const names = text.trim().split("\n").map(l => l.trim()).filter(l => l.length > 0);
                if (names.join(" ") === root.__inputDeviceNames.join(" "))
                    return;
                root.__inputDeviceNames = names;
                root.__rebuildNodes();
            }
        }
    }

    // ---- polling ---------------------------------------------------------

    // Volume moves often (media keys, other apps), so poll it briskly.
    Timer {
        interval: 1500
        running: true
        repeat: true
        onTriggered: volumeProbe.running = true
    }

    // Which device is default, and what devices exist, change rarely.
    Timer {
        interval: 4000
        running: true
        repeat: true
        onTriggered: root.__refreshDevices()
    }
}
