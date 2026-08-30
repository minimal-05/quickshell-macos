// Probe for the Quickshell.app identity (qs-bundle, PLATFORM.md "TCC
// identity"). Reports its own pid so tests/bundle.sh can ask `ps` which
// executable image the process is actually running -- the bundle's Mach-O,
// not the bin/qs script that exec'd it -- the LaunchServices bundle id when
// launched through `open`, and the environment the binary set for itself
// (src/launch/tools.cpp), which tests/one-binary.sh reads back from an
// instance started with no environment at all.
//
//   bin/qs-test tests/_probe_bundle.qml -- probe pid
//   bin/qs-test tests/_probe_bundle.qml -- probe bundleId
//   bin/qs-test tests/_probe_bundle.qml -- probe env

import Quickshell
import Quickshell.Io

ShellRoot {
    IpcHandler {
        target: "probe"
        function pid(): string { return String(Quickshell.processId); }
        // Set by LaunchServices for `open -a`, absent for a plain exec; the
        // executable path is the authoritative check, this is informational.
        function bundleId(): string { return Quickshell.env("__CFBundleIdentifier") || "unset"; }
        function env(): string {
            return ["PATH", "XDG_RUNTIME_DIR", "QML2_IMPORT_PATH", "QS_CONFIG_NAME"]
                .map(v => v + "=" + (Quickshell.env(v) || "")).join("\n");
        }
    }
}
