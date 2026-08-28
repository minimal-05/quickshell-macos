// Quickshell.Services.Pam shim for macOS — PamError
//
// REAL: values match upstream (src/services/pam/ipc.hpp).

import QtQuick

QtObject {
    enum Enum {
        StartFailed = 1,
        TryAuthFailed = 2,
        InternalError = 3
    }
}
