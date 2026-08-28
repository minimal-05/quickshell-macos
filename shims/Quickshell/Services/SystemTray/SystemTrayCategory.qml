pragma Singleton

// Quickshell.Services.SystemTray -- macOS compatibility shim (pure QML, no C++).
//
// Alias of Category.qml with identical values. See SystemTrayStatus.qml for why
// both spellings exist.

import QtQuick

QtObject {
    enum Enum {
        Hardware = 0,
        SystemServices = 1,
        ApplicationStatus = 2,
        Communications = 3
    }

    function toString(category: int): string {
        return Category.toString(category);
    }
}
