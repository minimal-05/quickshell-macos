#!/bin/bash
# Acceptance test for the Quickshell.app identity (bin/qs-bundle):
#   - the bundle is signed and carries the bundle id and usage strings;
#   - bin/quickshell is an exec wrapper (a script, not a symlink) onto the
#     bundle binary's real path;
#   - an instance started through the wrapper runs the bundle's Mach-O, so
#     NSBundle.mainBundle and TCC see Quickshell.app;
#   - bin/qs-test still works through the wrapper.
# Starts only its own throwaway instance (tests/_probe_bundle.qml).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/Quickshell.app"
EXE="$APP/Contents/MacOS/quickshell"
WRAP="$ROOT/bin/quickshell"
PROBE="$ROOT/tests/_probe_bundle.qml"
# Same runtime dir as qs-test, so the direct ipc call below finds the instance.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/quickshell-$UID}"
export QML2_IMPORT_PATH="$ROOT/shims${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"

fail=0
check() { if [ "$2" = "$3" ]; then printf '  PASS  %-34s %s\n' "$1" "$3"; else printf '  FAIL  %-34s got %s want %s\n' "$1" "$3" "$2"; fail=1; fi; }

[ -x "$EXE" ] || { echo "  FAIL  no $EXE (run bin/qs-build)"; exit 1; }

sig="$(codesign -dv "$APP" 2>&1)"
check "bundle identifier"      org.quickshell.shell "$(printf '%s\n' "$sig" | sed -n 's/^Identifier=//p')"
check "bundle signature valid" ok "$(codesign --verify --deep "$APP" 2>/dev/null && echo ok || echo bad)"
plist="$APP/Contents/Info.plist"
check "CFBundleExecutable"     quickshell "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null)"
check "LSUIElement"            true "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$plist" 2>/dev/null)"
for key in NSLocationWhenInUseUsageDescription NSAppleEventsUsageDescription NSMicrophoneUsageDescription NSBluetoothAlwaysUsageDescription; do
    check "$key" present "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1 && echo present || echo missing)"
done

check "wrapper is not a symlink" no  "$([ -L "$WRAP" ] && echo yes || echo no)"
check "wrapper execs bundle path" yes "$(/usr/bin/python3 -c 'import sys; t=open(sys.argv[1]).read(); print("yes" if "exec \""+sys.argv[2]+"\"" in t else "no")' "$WRAP" "$EXE")"

# Through the wrapper, as every launcher and `qs` does.
pid="$("$ROOT/bin/qs-test" "$PROBE" --shell 2>&1 | tail -1)"
case "$pid" in ''|*[!0-9]*) echo "  FAIL  qs-test --shell through the wrapper: $pid"; exit 1 ;; esac
check "instance runs the bundle Mach-O" "$EXE" "$(ps -o comm= -p "$pid" 2>/dev/null)"
check "ipc via wrapper reaches it" "$pid" "$("$WRAP" -p "$PROBE" ipc call probe pid 2>/dev/null | tr -d '\r\n')"
kill "$pid" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.3; done
kill -9 "$pid" 2>/dev/null

# A fresh one-shot qs-test, start to finish, through the wrapper.
check "qs-test through wrapper" PASS "$("$ROOT/bin/qs-test" "$PROBE" --expect-log 'Configuration Loaded' 2>&1 | awk '{print $1}' | head -1)"

exit $fail
