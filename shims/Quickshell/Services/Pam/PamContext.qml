import QtQuick

// Inert.
//
// macOS does ship OpenPAM, and upstream's PamContext is close to portable — but
// its only real use in shell configs is a lock screen, and macOS will not let a
// third party replace the login window. Rather than authenticate for real and
// imply a lock screen that cannot exist, this fails closed: start() completes
// immediately with Failure.
QtObject {
    id: root

    property bool active: false
    property string configDirectory: ""
    property string config: "login"
    property string user: ""
    property string message: ""
    property bool responseRequired: false
    property bool responseVisible: false

    signal pamMessage
    signal completed(int result)
    signal error(int error)

    function start(): bool {
        Qt.callLater(() => root.completed(1));   // PamResult.Failed
        return false;
    }

    function abort(): void {}

    function respond(response: string): void {}
}
