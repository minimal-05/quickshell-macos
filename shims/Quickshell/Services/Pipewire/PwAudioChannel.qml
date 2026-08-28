pragma Singleton

import QtQuick

// Quickshell.Services.Pipewire.PwAudioChannel - macOS compatibility shim.
//
// REAL: every member NAME from upstream node.hpp, and toString(). Declared as
// a QML `enum` because QML forbids property names beginning with a capital.
//
// CAVEAT, stated plainly: upstream's numbers come from SPA's channel map
// (SPA_AUDIO_CHANNEL_*), which is not available to a pure-QML shim. The
// numbers here are shim-local and only guaranteed self-consistent - i.e.
// `channel === PwAudioChannel.FrontLeft` and `toString(channel)` are correct,
// but a raw integer recorded from a real pipewire system will not map back.
// Nothing in a shell config depends on the raw integers, only on the names.
QtObject {
    id: root

    enum Channel {
        Unknown = 0,
        NA = 1,
        Mono = 2,
        FrontCenter = 3,
        FrontLeft = 4,
        FrontRight = 5,
        FrontLeftCenter = 6,
        FrontRightCenter = 7,
        FrontLeftWide = 8,
        FrontRightWide = 9,
        FrontCenterHigh = 10,
        FrontLeftHigh = 11,
        FrontRightHigh = 12,
        LowFrequencyEffects = 13,
        LowFrequencyEffects2 = 14,
        LowFrequencyEffectsLeft = 15,
        LowFrequencyEffectsRight = 16,
        SideLeft = 17,
        SideRight = 18,
        RearCenter = 19,
        RearLeft = 20,
        RearRight = 21,
        RearLeftCenter = 22,
        RearRightCenter = 23,
        TopCenter = 24,
        TopFrontCenter = 25,
        TopFrontLeft = 26,
        TopFrontRight = 27,
        TopFrontLeftCenter = 28,
        TopFrontRightCenter = 29,
        TopSideLeft = 30,
        TopSideRight = 31,
        TopRearCenter = 32,
        TopRearLeft = 33,
        TopRearRight = 34,
        BottomCenter = 35,
        BottomLeftCenter = 36,
        BottomRightCenter = 37,
        AuxRangeStart = 4096,
        AuxRangeEnd = 8191,
        CustomRangeStart = 65536
    }

    readonly property var __names: ["Unknown", "NA", "Mono", "FrontCenter", "FrontLeft", "FrontRight", "FrontLeftCenter", "FrontRightCenter", "FrontLeftWide", "FrontRightWide", "FrontCenterHigh", "FrontLeftHigh", "FrontRightHigh", "LowFrequencyEffects", "LowFrequencyEffects2", "LowFrequencyEffectsLeft", "LowFrequencyEffectsRight", "SideLeft", "SideRight", "RearCenter", "RearLeft", "RearRight", "RearLeftCenter", "RearRightCenter", "TopCenter", "TopFrontCenter", "TopFrontLeft", "TopFrontRight", "TopFrontLeftCenter", "TopFrontRightCenter", "TopSideLeft", "TopSideRight", "TopRearCenter", "TopRearLeft", "TopRearRight", "BottomCenter", "BottomLeftCenter", "BottomRightCenter"]

    function toString(value: int): string {
        if (value >= 65536)
            return "Custom " + (value - 65536);
        if (value >= 4096 && value <= 8191)
            return "Aux " + (value - 4096);
        return root.__names[value] ?? "Unknown";
    }
}
