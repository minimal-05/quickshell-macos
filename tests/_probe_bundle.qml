// Probe for the Quickshell.app identity (bin/qs-bundle, PLATFORM.md "TCC
// identity"). Reports its own pid so tests/bundle.sh can ask `ps` which
// executable image the process is actually running -- the bundle's Mach-O,
// not the bin/quickshell wrapper -- and the LaunchServices bundle id when
// launched through `open`.
//
//   bin/qs-test tests/_probe_bundle.qml -- probe pid
//   bin/qs-test tests/_probe_bundle.qml -- probe bundleId

import Quickshell
import Quickshell.Io

ShellRoot {
    IpcHandler {
        target: "probe"
        function pid(): string { return String(Quickshell.processId); }
        // Set by LaunchServices for `open -a`, absent for a plain exec; the
        // executable path is the authoritative check, this is informational.
        function bundleId(): string { return Quickshell.env("__CFBundleIdentifier") || "unset"; }
    }
}
