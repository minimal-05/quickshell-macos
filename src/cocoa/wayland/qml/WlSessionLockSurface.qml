// Quickshell.Wayland shim for macOS — WlSessionLockSurface
//
// FULLY INERT, but structurally honest: it is an Item, so children declared
// inside it (upstream's `data` default property) parent correctly and any
// anchors/size bindings in a consumer config resolve instead of throwing.
// It is never shown, because WlSessionLock never instantiates it — see the
// comment there for why session locking cannot be shimmed on macOS.
//
// `visible` is Item's own and starts false since nothing ever parents this
// into a window. `screen` is always null. `color` is stored and unused.
// `contentItem` returns this item, matching how consumers reparent into it.

import QtQuick

Item {
    id: root

    visible: false

    readonly property Item contentItem: root
    property var screen: null
    property color color: "white"
}
