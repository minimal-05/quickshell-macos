// Quickshell.Wayland shim for macOS — WlSessionLockSurface
//
// REAL now that WlSessionLock instantiates it (see the comment there): a
// plain Item, resized to fill the PanelWindow it's loaded into (Loader gives
// a loaded item its own size when the Loader itself has an explicit size),
// hosting whatever a config parents into it via the default `data` property.
//
// `contentItem` returns this item, matching how consumers reparent into it.
// `screen` is set by WlSessionLock after loading. `color` is accepted and
// stored but not painted -- the PanelWindow underneath already sets its own
// background.

import QtQuick

Item {
    id: root

    readonly property Item contentItem: root
    property var screen: null
    property color color: "white"
}
