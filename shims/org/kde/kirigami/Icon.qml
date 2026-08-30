import QtQuick
import QtQuick.Effects
import Quickshell

// Stand-in for Kirigami.Icon, the one KDE Frameworks type configs like end-4's
// actually use (for application icons).
//
// KDE Frameworks is not realistically installable on macOS and there is no XDG
// icon theme, so a bare icon *name* resolves through Quickshell.iconPath, which
// this fork backs with LaunchServices (src/cocoa/appicon.mm): an app name,
// bundle id or desktop-entry stem becomes that app's icon. Paths, urls and
// image:// sources load as-is. A name nothing can resolve tries `fallback` the
// same way, and only then the first letter of the name in a tile, which keeps
// application lists legible rather than blank.
//
// REAL: source, fallback, isMask + color (alpha-mask recolour, as Kirigami's
// KIconLoader does it), animated (fade on source change), status.
// INERT: roundToIconSize (LaunchServices renders any size), selected (no
// highlight palette here), placeholder.
Item {
    id: root

    property var source: ""
    property bool isMask: false
    property color color: "transparent"
    property bool roundToIconSize: true
    property bool animated: false
    property bool selected: false
    property string fallback: "unknown"
    property string placeholder: ""

    // Image.Null / Loading / Ready / Error, as Kirigami reports it: Error means
    // nothing resolved and the letter tile is showing.
    readonly property int status: root.resolvedSource === ""
                                  ? (root.sourceString === "" ? Image.Null : Image.Error)
                                  : image.status

    implicitWidth: 24
    implicitHeight: 24

    readonly property string sourceString: source === undefined || source === null ? "" : String(source)

    // Quickshell.iconPath(name, true) answers "" for a name the platform cannot
    // resolve, before Image gets involved, so a miss never shows the icon
    // provider's placeholder.
    function resolve(name: string): string {
        if (name.length === 0)
            return "";
        if (name.indexOf("/") !== -1 || name.indexOf(":") !== -1)
            return name;
        return Quickshell.iconPath(name, true);
    }

    readonly property string primarySource: root.resolve(root.sourceString)
    readonly property string fallbackSource: root.resolve(root.fallback)

    // 0: the source, 1: the fallback, 2: the letter tile. Advanced by an
    // Image.Error (a path that resolved but does not load), reset when either
    // name changes.
    property int stage: 0
    onSourceStringChanged: root.stage = 0
    onFallbackChanged: root.stage = 0

    readonly property string resolvedSource: {
        if (root.stage === 0 && root.primarySource !== "")
            return root.primarySource;
        if (root.stage <= 1 && root.fallbackSource !== "")
            return root.fallbackSource;
        return "";
    }

    readonly property bool masked: root.isMask && root.resolvedSource !== ""
    // Kirigami reads the theme's text colour for a transparent mask colour.
    readonly property color maskColor: root.color.a > 0 ? root.color : root.palette.windowText

    onResolvedSourceChanged: {
        if (root.animated)
            fade.restart();
    }

    NumberAnimation {
        id: fade

        target: content
        property: "opacity"
        from: 0
        to: 1
        duration: 250
    }

    Item {
        id: content

        anchors.fill: parent

        Image {
            id: image

            anchors.fill: parent
            // Deliberately NOT gated on `status === Image.Ready`. A source is
            // reloaded whenever it changes, and an asynchronous reload passes
            // back through Loading, so a Ready-gated binding drops this to
            // invisible and shows the placeholder underneath on every refresh.
            // In the bar that is constant: the workspace icons re-resolve on
            // each poll, and the effect that samples this item captures the
            // placeholder rather than the icon. Staying visible keeps the
            // previous frame on screen across a reload, which is what the real
            // Kirigami.Icon does.
            visible: root.resolvedSource !== ""
            // Hidden by opacity, not `visible`, while masked: the effect below
            // samples this item's texture, and an Image that is not rendered
            // never uploads one.
            opacity: root.masked ? 0 : 1
            source: root.resolvedSource
            sourceSize.width: Math.round(root.width)
            sourceSize.height: Math.round(root.height)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true

            onStatusChanged: {
                if (image.status !== Image.Error)
                    return;
                root.stage = root.stage === 0 && root.resolvedSource === root.primarySource ? 1 : 2;
            }
        }

        Rectangle {
            id: fill

            anchors.fill: parent
            visible: false
            color: root.maskColor
        }

        // isMask replaces every opaque pixel with `color`, keeping only the
        // shape. MultiEffect's colorization weights by luminance, so a black
        // glyph would stay black; the mask path gives the exact KIconLoader
        // result for any source colour. `source` is null until needed so the
        // effect's offscreen buffer only exists for icons that are masked.
        MultiEffect {
            anchors.fill: parent
            visible: root.masked
            source: root.masked ? fill : null
            maskEnabled: true
            maskSource: image
        }

        Rectangle {
            anchors.fill: parent
            // Only a name that cannot be resolved at all, not one still loading.
            visible: root.resolvedSource === "" || image.status === Image.Error
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
}
