pragma Singleton

// Quickshell.Services.SystemTray -- macOS compatibility shim (pure QML, no C++).
//
// Mirrors the `SystemTray` singleton (quickshell/src/services/status_notifier/qml.hpp).
//
// ENTIRELY INERT, by necessity rather than by laziness.
//
// On Linux, quickshell registers as a org.kde.StatusNotifierWatcher host and every
// tray-capable application publishes its icon to it over D-Bus. macOS has no
// counterpart: menu-bar extras are NSStatusItems owned by their own process and
// drawn by the system menu bar. There is no public API -- and since the accessibility
// rework, no reliable private one -- for a third-party process to enumerate, render,
// or click other applications' menu-bar items. Nothing short of an accessibility-API
// screen-scrape gets close, and that is a permission prompt and a fragile hack, not
// a shim.
//
// So `items.values` is always []. Consumer configs that build their tray from it
// (end-4 TrayService.qml, caelestia Tray.qml, dank SystemTrayBar.qml all do
// `SystemTray.items.values.filter(...)`) get an empty list and render an empty tray,
// which is the honest outcome. Nothing is faked.

import QtQuick
import Quickshell

Singleton {
    // ObjectModel-SHAPED, exposing `.values` the way every consumer config on disk
    // reads it. This is NOT a QAbstractListModel, so unlike upstream it cannot be
    // handed to a Repeater as `model:` directly -- no config found does that.
    readonly property QtObject items: QtObject {
        readonly property var values: []
        readonly property int count: 0

        function indexOf(object): int {
            return -1;
        }
    }
}
