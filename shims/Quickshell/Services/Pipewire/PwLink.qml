import QtQuick

// Quickshell.Services.Pipewire.PwLink - macOS compatibility shim.
//
// FULLY INERT. macOS/CoreAudio exposes no routing graph, so Pipewire.links is
// permanently empty and nothing ever constructs one of these. It exists only
// so that `import Quickshell.Services.Pipewire` configs that name PwLink as a
// property type still resolve.
QtObject {
    id: root

    property int __id: 0
    readonly property int id: root.__id

    property PwNode target: null
    property PwNode source: null
    property int state: PwLinkState.Unlinked
}
