import QtQuick

// Quickshell.Services.Pipewire.PwLinkGroup - macOS compatibility shim.
//
// FULLY INERT, for the same reason as PwLink: there is no routing graph.
// Pipewire.linkGroups stays empty, so consumers such as end-4's Privacy.qml
// (which filters linkGroups to detect screensharing and mic activity) get an
// empty list and report "nothing active" instead of throwing.
QtObject {
    id: root

    property PwNode target: null
    property PwNode source: null
    property int state: PwLinkState.Unlinked
}
