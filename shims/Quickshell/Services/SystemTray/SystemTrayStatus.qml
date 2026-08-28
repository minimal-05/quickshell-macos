pragma Singleton

// Quickshell.Services.SystemTray -- macOS compatibility shim (pure QML, no C++).
//
// Alias of Status.qml with identical values. Upstream's QML type is named `Status`
// (item.hpp, namespace qs::service::sni::Status), which is what end-4 uses, but the
// longer `SystemTrayStatus` spelling appears in Quickshell's docs and in some
// configs. Both are provided so either spelling resolves.

import QtQuick

QtObject {
    enum Enum {
        Passive = 0,
        Active = 1,
        NeedsAttention = 2
    }

    function toString(status: int): string {
        return Status.toString(status);
    }
}
