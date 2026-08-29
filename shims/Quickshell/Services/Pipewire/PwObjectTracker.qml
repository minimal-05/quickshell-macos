import QtQuick

// Quickshell.Services.Pipewire.PwObjectTracker - macOS compatibility shim.
//
// FULLY INERT, and correctly so. Upstream this type refcounts pipewire object
// bindings so that a bound node's volume/mute/properties become valid. In this
// shim every node is always "bound": the CoreAudio HAL pushes every device's
// state to the singleton regardless of who is watching. So tracking is a no-op holder
// and every property upstream marks "invalid unless bound" is simply always
// as valid as macOS can make it.
//
// `objects` is deliberately `var`, not `list<QtObject>`, because consumers
// write things like `objects: [sink, source]` where either may still be null
// during startup.
QtObject {
    id: root

    property var objects: []
}
