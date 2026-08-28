import QtQuick

// Inert — see PolkitAgent.qml.
QtObject {
    id: root

    property string message: ""
    property string iconName: ""
    property string actionId: ""
    property string cookie: ""
    property list<var> identities: []
    property var selectedIdentity: null
    property bool isResponseRequired: false
    property string inputPrompt: ""
    property bool responseVisible: false
    property string supplementaryMessage: ""
    property bool supplementaryIsError: false
    property bool isCompleted: false
    property bool isSuccessful: false
    property bool isCancelled: false
    property bool failed: false

    signal authenticationFailed
    signal authenticationSucceeded

    function submit(value: string): void {}
    function cancelAuthenticationRequest(): void {}
}
