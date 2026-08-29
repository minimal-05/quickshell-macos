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
        first = { total: s.cpuTotal, idle: s.cpuIdle, user: s.cpuUser, system: s.cpuSystem, nice: s.cpuNice };
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
            for (const k of ["idle", "user", "system", "nice"]) {
                const now = s["cpu" + k[0].toUpperCase() + k.slice(1)];
                if (now < first[k]) fails.push(`cpu${k} went backwards ${first[k]} -> ${now}`);
            }
            if (!(s.memTotal > 0)) fails.push("memTotal 0");
            if (s.memUsed + s.memAvailable !== s.memTotal) fails.push("used + available != total");
            if (!(s.memUsed > 0 && s.memUsed < s.memTotal)) fails.push(`memUsed ${s.memUsed}`);
            if (!(s.memActive + s.memWired + s.memCompressed === s.memUsed)) fails.push("used != active+wired+compressed");
            if (!(s.pageSize === 4096 || s.pageSize === 16384)) fails.push(`pageSize ${s.pageSize}`);
            if (!(s.swapFree <= s.swapTotal && s.swapUsed <= s.swapTotal)) fails.push(`swap ${s.swapUsed}/${s.swapFree}/${s.swapTotal}`);
            if (s.loadAverage.length !== 3 || !(s.loadAverage[0] >= 0)) fails.push(`loadAverage ${JSON.stringify(s.loadAverage)}`);
            if (s.interval !== 1000) fails.push(`interval ${s.interval}`);
            return fails.length ? "fail: " + fails.join(", ") : "ok";
        }

        function memTotal(): string { return String(Cocoa.SystemStats.memTotal); }

        // sample() outside the timer must also advance the counters.
        function manual(): string {
            const s = Cocoa.SystemStats;
            const before = samples;
            s.sample();
            return samples === before + 1 ? "ok" : "sampled not emitted";
        }

        function dump(): string {
            const s = Cocoa.SystemStats;
            const out = {};
            for (const k of ["interval", "cpuUser", "cpuSystem", "cpuIdle", "cpuNice", "cpuTotal", "memTotal", "memUsed", "memAvailable", "memFree", "memWired", "memCompressed", "pageSize", "swapTotal", "swapUsed", "swapFree", "loadAverage"])
                out[k] = s[k];
            out.samples = samples;
            return JSON.stringify(out);
        }
    }
}
