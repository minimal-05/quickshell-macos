// Quickshell.Services.Pam shim for macOS — PamResult
//
// REAL: values match upstream (src/services/pam/ipc.hpp).
// Read as PamResult.Success etc., exactly as on Linux.

import QtQuick

QtObject {
    enum Enum {
        Success = 0,
        Failed = 1,
        Error = 2,
        MaxTries = 3
    }
}
