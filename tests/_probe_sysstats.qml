// Acceptance probe for Quickshell.Cocoa.SystemStats. Takes the singleton's
// first sample at load and compares a later one against it.
//   bin/qs-test tests/_probe_sysstats.qml -- sysstats check == ok   (after > 1 interval)
//   bin/qs-test tests/_probe_sysstats.qml -- sysstats memTotal      (compare to sysctl -n hw.memsize)
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Cocoa as Cocoa

ShellRoot {
    property var first: null
    property int samples: 0

    Component.onCompleted: {
        const s = Cocoa.SystemStats;
        first = { total: s.cpuTotal, idle: s.cpuIdle };
        s.interval = 1000;
    }

    Connections {
        target: Cocoa.SystemStats
        function onSampled() { samples++; }
    }

    IpcHandler {
        target: "sysstats"

        function check(): string {
            const s = Cocoa.SystemStats;
            const fails = [];
            if (samples < 1) fails.push("no timer sample yet");
            if (!(s.cpuTotal > first.total)) fails.push(`cpuTotal ${first.total} -> ${s.cpuTotal} not increasing`);
            if (s.cpuIdle < first.idle) fails.push(`cpuIdle went backwards ${first.idle} -> ${s.cpuIdle}`);
            if (!(s.memTotal > 0)) fails.push("memTotal 0");
            if (s.memUsed + s.memAvailable !== s.memTotal) fails.push("used + available != total");
            if (!(s.memUsed > 0 && s.memUsed < s.memTotal)) fails.push(`memUsed ${s.memUsed}`);
            if (!(s.swapFree <= s.swapTotal)) fails.push(`swap ${s.swapFree}/${s.swapTotal}`);
            if (!(s.idleSeconds() >= 0 && s.idleSeconds() < 86400 * 365)) fails.push(`idleSeconds ${s.idleSeconds()}`);
            if (s.interval !== 1000) fails.push(`interval ${s.interval}`);
            return fails.length ? "fail: " + fails.join(", ") : "ok";
        }

        function memTotal(): string { return String(Cocoa.SystemStats.memTotal); }

        function dump(): string {
            const s = Cocoa.SystemStats;
            const out = {};
            for (const k of ["interval", "cpuIdle", "cpuTotal", "memTotal", "memUsed", "memAvailable", "swapTotal", "swapFree"])
                out[k] = s[k];
            out.samples = samples;
            return JSON.stringify(out);
        }
    }
}
