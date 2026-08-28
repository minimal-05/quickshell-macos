pragma Singleton

import QtQuick

// Quickshell.Services.Pipewire.PwLinkState - macOS compatibility shim.
//
// REAL: the values, faithful to pipewire's PW_LINK_STATE_* (which is where
// upstream link.hpp takes them from). Declared as a QML `enum` because QML
// forbids capitalised property names.
//
// INERT in practice: no link ever exists on macOS, so nothing reports one of
// these. Declared so `state === PwLinkState.Active` evaluates to false rather
// than throwing on an undefined member.
QtObject {
    id: root

    enum State {
        Error = -2,
        Unlinked = -1,
        Init = 0,
        Negotiating = 1,
        Allocating = 2,
        Paused = 3,
        Active = 4
    }

    function toString(value: int): string {
        switch (value) {
        case -2:
            return "Error";
        case -1:
            return "Unlinked";
        case 0:
            return "Init";
        case 1:
            return "Negotiating";
        case 2:
            return "Allocating";
        case 3:
            return "Paused";
        case 4:
            return "Active";
        }
        return "Unknown";
    }
}
