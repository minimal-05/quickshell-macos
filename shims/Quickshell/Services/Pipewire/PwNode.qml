import QtQuick

// Quickshell.Services.Pipewire.PwNode - macOS compatibility shim.
//
// REAL: one node per CoreAudio output/input device, as enumerated by
// SwitchAudioSource. `name`/`description`/`nickname` all carry the CoreAudio
// device name (macOS exposes only the one string), `isSink` distinguishes
// output from input, `type` carries the matching PwNodeType flags, and
// `audio` is live for whichever node is currently the system default.
// INERT:
//   - `isStream` is always false. macOS has no per-application audio nodes
//     reachable without a CoreAudio HAL plugin, so an application mixer will
//     correctly render as empty rather than wrong.
//   - `id` is a synthetic stable integer, not a pipewire object id.
//   - `properties` carries only the couple of keys end-4 reads
//     (`node.name`, `node.description`, `device.description`).
//
// `id` cannot be written declaratively in QML (the parser always reads
// `id:` as an object id), so it is a read-only alias over `__id`, which the
// owning singleton assigns from JS.
QtObject {
    id: root

    property int __id: 0
    readonly property int id: root.__id

    property string name: ""
    property string description: ""
    property string nickname: ""

    property bool isSink: true
    property bool isStream: false
    property int type: PwNodeType.Untracked

    property var properties: ({})

    property PwNodeAudio audio: PwNodeAudio {}

    property bool ready: false
}
