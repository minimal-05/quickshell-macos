pragma Singleton

import QtQuick

// Stand-in for KSyntaxHighlighting's Repository. KDE Frameworks is not
// realistically installable on macOS, and this is used in exactly one place —
// naming the language on an AI-chat code block. Returns an object with the
// `.name` consumers read, so the label says "python" instead of throwing; no
// highlighting definitions are actually loaded.
QtObject {
    id: root

    function definitionForName(name: string): var {
        const clean = (name && name.length > 0) ? name : "plaintext";
        return {
            name: clean,
            translatedName: clean,
            isValid: false,
            extensions: [],
            mimeTypes: []
        };
    }

    function definitionForFileName(fileName: string): var {
        return root.definitionForName("plaintext");
    }

    function definitionForMimeType(mimeType: string): var {
        return root.definitionForName("plaintext");
    }

    readonly property var definitions: []
    readonly property var themes: []

    function theme(name: string): var {
        return ({
                name: name ?? "",
                isValid: false
            });
    }

    function defaultTheme(): var {
        return root.theme("default");
    }
}
