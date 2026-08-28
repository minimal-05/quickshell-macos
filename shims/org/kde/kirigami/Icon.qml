import QtQuick

// Stand-in for Kirigami.Icon, the one KDE Frameworks type configs like end-4's
// actually use (for application icons).
//
// KDE Frameworks is not realistically installable on macOS, and there is no XDG
// icon theme here either, so a bare icon *name* has nothing to resolve against.
// This renders real sources (file paths, image:// providers, URLs) and falls
// back to the first letter of the name for everything else, which keeps
// application lists legible rather than blank.
Item {
    id: root

    property var source: ""
    property bool isMask: false
    property color color: "transparent"
    property bool roundToIconSize: true
    property bool animated: false
    property bool selected: false
    property int status: 0
    property string fallback: ""
    property string placeholder: ""

    implicitWidth: 24
    implicitHeight: 24

    readonly property string sourceString: source === undefined || source === null ? "" : String(source)

    // A path, url or image provider is loadable; a bare theme name is not.
    readonly property bool loadable: sourceString.length > 0
                                     && (sourceString.indexOf("/") !== -1 || sourceString.indexOf(":") !== -1)

    Image {
        id: image

        anchors.fill: parent
        // Deliberately NOT gated on `status === Image.Ready`. A source is reloaded
        // whenever it changes, and an asynchronous reload passes back through
        // Loading, so a Ready-gated binding drops this to invisible and shows the
        // placeholder underneath on every refresh. In the bar that is constant:
        // the workspace icons re-resolve on each poll, and the effect that samples
        // this item captures the placeholder rather than the icon. Staying visible
        // keeps the previous frame on screen across a reload, which is what the
        // real Kirigami.Icon does.
        visible: root.loadable && image.status !== Image.Error
        source: root.loadable ? root.sourceString : ""
        sourceSize.width: Math.round(root.width)
        sourceSize.height: Math.round(root.height)
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
    }

    Rectangle {
        anchors.fill: parent
        // Only a name that cannot be resolved at all, not one still loading.
        visible: !root.loadable || image.status === Image.Error
        radius: width * 0.25
        color: "#2B2930"

        Text {
            anchors.centerIn: parent
            text: {
                const s = root.sourceString;
                if (s.length === 0)
                    return "?";
                const name = s.substring(s.lastIndexOf("/") + 1);
                return name.length > 0 ? name.charAt(0).toUpperCase() : "?";
            }
            color: "#E6E0E9"
            font.pixelSize: Math.max(9, root.height * 0.5)
            font.weight: Font.Medium
        }
    }
}
