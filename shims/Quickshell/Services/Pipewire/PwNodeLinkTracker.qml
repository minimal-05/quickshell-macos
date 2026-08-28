import QtQuick

// Quickshell.Services.Pipewire.PwNodeLinkTracker - macOS compatibility shim.
//
// FULLY INERT. Upstream this reports the link groups connected to a node;
// there is no link graph on macOS, so `linkGroups` is permanently empty.
// `node` is a real read/write property so bindings that assign to it work.
QtObject {
    id: root

    property PwNode node: null
    readonly property var linkGroups: []
}
