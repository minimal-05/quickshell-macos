pragma Singleton

import QtQuick

// Quickshell.Services.Pipewire.PwNodeType - macOS compatibility shim.
//
// REAL and bit-for-bit faithful to upstream node.hpp: the flag bits and every
// composite are the same integers, so `node.type & PwNodeType.Audio` and
// `node.type === PwNodeType.AudioSource` behave exactly as on Linux.
// Declared as a QML `enum` because QML forbids capitalised property names.
//
// INERT: the Video and Stream bits are never set by this shim, because macOS
// gives us neither a video graph nor per-application audio nodes. Consumers
// filtering for them get empty lists rather than errors.
QtObject {
    id: root

    enum Type {
        Untracked = 0,
        Audio = 1,
        Video = 2,
        Stream = 4,
        Source = 8,
        Sink = 16,
        AudioSink = 17,      // Audio | Sink
        AudioSource = 9,     // Audio | Source
        AudioDuplex = 25,    // Audio | Sink | Source
        AudioOutStream = 21, // Audio | Sink | Stream
        AudioInStream = 13,  // Audio | Source | Stream
        VideoSource = 10,    // Video | Source
        VideoSink = 18       // Video | Sink
    }

    function toString(type: int): string {
        if (type === 0)
            return "Untracked";

        const parts = [];
        if (type & 1)
            parts.push("Audio");
        if (type & 2)
            parts.push("Video");
        if (type & 4)
            parts.push("Stream");
        if (type & 8)
            parts.push("Source");
        if (type & 16)
            parts.push("Sink");
        return parts.join(" | ");
    }
}
