import QtQuick

// Quickshell.Services.Pipewire.PwNode - macOS compatibility shim.
//
// REAL: one node per direction of every CoreAudio device (see Pipewire.qml).
// `name` is the device UID (stable across replugs, the closest thing to
// upstream's `node.name`), `description` and `nickname` carry the user-facing
// device name, `isSink` distinguishes output from input, `type` carries the
// matching PwNodeType flags, and `audio` is live on every node.
// INERT:
//   - `isStream` is always false. macOS has no per-application audio nodes
//     reachable without a process tap, so an application mixer will
//     correctly render as empty rather than wrong.
//   - `id` is the CoreAudio AudioObjectID (offset for the source side of a
//     duplex device), not a pipewire object id.
//   - `properties` carries the handful of keys configs read (`node.name`,
//     `node.description`, `device.description`, `device.api`, `device.bus`,
//     `media.class`).
//
// `id` cannot be written declaratively in QML (the parser always reads
// `id:` as an object id), so it is a read-only alias over `__id`, which the
// owning singleton assigns from JS.
QtObject {
    id: root

    property int __id: 0
    readonly property int id: root.__id

    // The Quickshell.Cocoa.CoreAudioDevice behind this node; what the
    // singleton hands to CoreAudio.defaultOutput/defaultInput on a switch.
    property var __device: null

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
