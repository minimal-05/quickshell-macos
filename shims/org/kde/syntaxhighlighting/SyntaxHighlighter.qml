import QtQuick

// Stand-in for KSyntaxHighlighting's SyntaxHighlighter. It attaches to a
// TextEdit's textDocument on Linux and recolours it; here it accepts the same
// properties and leaves the text alone. Code blocks render as plain monospace.
QtObject {
    property var textEdit: null
    property var document: null
    property var repository: null
    property var definition: null
    property var theme: null
}
