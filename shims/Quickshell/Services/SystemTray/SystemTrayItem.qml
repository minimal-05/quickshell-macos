// Quickshell.Services.SystemTray -- macOS compatibility shim (pure QML, no C++).
//
// Mirrors qs::service::sni::StatusNotifierItem, exported to QML as `SystemTrayItem`
// (quickshell/src/services/status_notifier/item.hpp). Upstream this is
// QML_UNCREATABLE and backed by a org.kde.StatusNotifierItem D-Bus peer.
//
// ENTIRELY INERT: no instance of this type is ever produced on macOS. See
// SystemTray.qml for why. It exists so that
//   - `property SystemTrayItem x` declarations in consumer configs compile,
//   - delegates written against `modelData.icon` / `item.status` / `item.activate()`
//     type-check and would work verbatim if items ever appeared.
//
// `menu` is deliberately null rather than a fake handle: consumer configs guard it
// (`if (item.hasMenu)`) and passing a bogus object to QsMenuOpener would be worse
// than passing nothing. `hasMenu` is false, so those guards short-circuit.

import QtQuick

QtObject {
    property string id: ""
    property string title: ""
    property int status: Status.Passive
    property int category: Category.ApplicationStatus
    property string icon: ""
    property string tooltipTitle: ""
    property string tooltipDescription: ""
    property bool hasMenu: false
    property bool onlyMenu: false
    // Upstream: DBusMenuHandle*. There is no D-Bus menu to hand out.
    readonly property var menu: null

    function activate(): void {}
    function secondaryActivate(): void {}
    function scroll(delta: int, horizontal: bool): void {}
    function display(parentWindow: QtObject, relativeX: int, relativeY: int): void {}
}
