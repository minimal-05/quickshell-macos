#!/bin/bash
# Acceptance test for the Quickshell.app identity (qs-bundle):
#   - the bundle is signed and carries the bundle id and usage strings;
#   - bin/qs is a script (not a symlink) that execs the bundle binary's real
#     path, and there is no bin/quickshell wrapper any more;
#   - an instance started through bin/qs -- the way every launcher starts one --
#     runs the bundle's Mach-O, so NSBundle.mainBundle and TCC see Quickshell.app;
#   - ipc reaches it through qs, and through the Mach-O run with no
#     environment at all (it sets XDG_RUNTIME_DIR itself);
#   - bin/qs-test works end to end.
# Always this tree's own bundle: QS_BINARY is not consulted, since the bundle
# is what is under test. Starts only its own throwaway instance
# (tests/_probe_bundle.qml).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/Quickshell.app"
EXE="$APP/Contents/MacOS/quickshell"
QS="$ROOT/bin/qs"
PROBE="$ROOT/tests/_probe_bundle.qml"
# Same runtime dir as qs-test, so the direct ipc calls below find the instance.
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
for key in NSLocationWhenInUseUsageDescription NSAppleEventsUsageDescription NSMicrophoneUsageDescription NSBluetoothAlwaysUsageDescription NSScreenCaptureUsageDescription; do
    check "$key" present "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1 && echo present || echo missing)"
done

check "qs is not a symlink"      no  "$([ -L "$QS" ] && echo yes || echo no)"
check "qs execs bundle path" yes "$(/usr/bin/python3 -c 'import sys; t=open(sys.argv[1]).read(); print("yes" if "/Quickshell.app/Contents/MacOS/quickshell\"" in t else "no")' "$QS")"
check "no bin/quickshell wrapper" no  "$([ -e "$ROOT/bin/quickshell" ] && echo yes || echo no)"

# Through qs, as every launcher does.
pid="$("$ROOT/bin/qs-test" "$PROBE" --binary "$QS" --shell 2>&1 | tail -1)"
case "$pid" in ''|*[!0-9]*) echo "  FAIL  qs-test --shell through qs: $pid"; exit 1 ;; esac
check "instance runs the bundle Mach-O" "$EXE" "$(ps -o comm= -p "$pid" 2>/dev/null)"
check "ipc via qs reaches it"      "$pid" "$("$QS"   -p "$PROBE" ipc call probe pid 2>/dev/null | tr -d '\r\n')"
check "ipc via bare Mach-O, no env"  "$pid" "$(env -i HOME="$HOME" "$EXE" -p "$PROBE" ipc call probe pid 2>/dev/null | tr -d '\r\n')"
kill "$pid" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.3; done
kill -9 "$pid" 2>/dev/null

# A fresh one-shot qs-test, start to finish, through qs.
check "qs-test through qs" PASS "$("$ROOT/bin/qs-test" "$PROBE" --binary "$QS" --expect-log 'Configuration Loaded' 2>&1 | awk '{print $1}' | head -1)"

exit $fail
