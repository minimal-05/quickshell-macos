import QtQuick

// Inert. macOS privilege escalation goes through Authorization Services and the
// system's own dialog; a third party cannot register as the auth agent the way
// a polkit agent does on Linux. This exists so configs that declare a
// PolkitAgent still load — it never fires an authentication request, so
// `isActive` stays false and `flow` stays null.
QtObject {
    id: root

    property bool isActive: false
    property bool registered: false
    property var flow: null
    property list<var> flows: []

    signal authenticationRequestStarted
    signal authenticationRequestEnded

    function cancel(): void {}
}
