import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// Throwaway root that instantiates only services/ResourceUsage.qml from the
// shell config. `qs.*` imports resolve against the root file's directory, so
// tests/sysstats.sh copies this next to a scratch view of the config and runs
//   quickshell -p <scratch>/_probe_resourceusage.qml ipc call probe check   -> "ok"
// (needs two samples, i.e. > updateInterval of wall time, before checking)
ShellRoot {
    // Singletons are created on first reference; touch it at load so the
    // Timer starts sampling before the first ipc call.
    Component.onCompleted: console.log("probe: ResourceUsage armed, historyLength", ResourceUsage.historyLength)

    IpcHandler {
        target: "probe"

        function samples(): string { return String(ResourceUsage.cpuUsageHistory.length) }
        function cpu(): string { return String(ResourceUsage.cpuUsage) }
        function mem(): string {
            return `total=${ResourceUsage.memoryTotal} free=${ResourceUsage.memoryFree} swapTotal=${ResourceUsage.swapTotal} swapFree=${ResourceUsage.swapFree}`
        }
        function check(): string {
            const r = ResourceUsage
            const fails = []
            if (r.cpuUsageHistory.length < 2) fails.push(`samples=${r.cpuUsageHistory.length}`)
            if (!r.previousCpuStats || !(r.previousCpuStats.total > 0)) fails.push("no tick baseline")
            if (!(r.cpuUsage >= 0 && r.cpuUsage <= 1)) fails.push(`cpuUsage=${r.cpuUsage}`)
            if (r.cpuUsageHistory.length >= 2 && !(r.cpuUsage > 0)) fails.push("cpuUsage still 0 after two samples")
            // memory is kB: 1 GB .. 4 TB, used < total, swap sane
            if (!(r.memoryTotal > 1048576 && r.memoryTotal < 4294967296)) fails.push(`memoryTotal=${r.memoryTotal}`)
            if (!(r.memoryFree > 0 && r.memoryFree < r.memoryTotal)) fails.push(`memoryFree=${r.memoryFree}`)
            if (!(r.swapTotal >= 0 && r.swapFree >= 0 && r.swapFree <= r.swapTotal)) fails.push(`swap=${r.swapTotal}/${r.swapFree}`)
            return fails.length ? "fail: " + fails.join(", ") : "ok"
        }
    }
}
