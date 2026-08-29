#!/bin/bash
# Acceptance run for the pure-QML service shims (UPower, Bluetooth, Mpris,
# kirigami Icon). Each probe is started as its own throwaway instance, given a
# few seconds for its first poll to land, then asked `check` over IPC.
#
#   tests/shims.sh                 run every probe's check
#   tests/shims.sh upower mpris    a subset
#   PERF=60 tests/shims.sh upower  also print qs-perf --children over 60 s
#
# The shims are what QML2_IMPORT_PATH points at, which qs-test sets to this
# tree's shims/. QS_BINARY selects the quickshell binary (defaults to
# bin/quickshell of this tree).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTLE="${SETTLE:-5}"
BINARY="${QS_BINARY:-$ROOT/bin/quickshell}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/quickshell-$UID}"
# qs-test refuses a second run on a root that is already up, so IPC goes
# straight to the binary; the instance is keyed on the root path.
ipc() { "$BINARY" -p "$1" ipc call "${@:2}" 2>/dev/null | tr -d '\r'; }
PERF="${PERF:-0}"
probes=("$@")
[ ${#probes[@]} -gt 0 ] || probes=(upower bluetooth mpris kirigami)

fail=0
for name in "${probes[@]}"; do
    qml="$ROOT/tests/_probe_$name.qml"
    pid="$("$ROOT/bin/qs-test" "$qml" --shell)" || { echo "  FAIL  $name did not start"; fail=1; continue; }
    sleep "$SETTLE"
    got="$(ipc "$qml" "$name" check)"
    # A Mac with nothing loaded in any player legitimately has no Mpris player.
    if [ "$got" = "ok" ] || { [ "$name" = mpris ] && [ "$got" = "no-player" ]; }; then
        printf '  PASS  %-12s check == %s\n' "$name" "$got"
    else
        printf '  FAIL  %-12s check == %s\n' "$name" "$got"; fail=1
    fi
    case "$name" in
        upower)
            want="$(pmset -g batt | sed -n 's/.*[[:space:]]\([0-9]*\)%.*/\1/p' | head -1)"
            got="$(ipc "$qml" upower percentage)"
            if [ "$got" = "$want" ]; then printf '  PASS  %-12s percentage %s == pmset\n' "$name" "$got"
            else printf '  FAIL  %-12s percentage %s, pmset says %s\n' "$name" "$got" "$want"; fail=1; fi ;;
        bluetooth)
            want="$(blueutil --paired --format json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
            got="$(ipc "$qml" bluetooth count)"
            if [ "$got" -ge "$want" ] 2>/dev/null; then printf '  PASS  %-12s %s devices (>= %s paired)\n' "$name" "$got" "$want"
            else printf '  FAIL  %-12s %s devices, blueutil has %s paired\n' "$name" "$got" "$want"; fail=1; fi ;;
    esac
    if [ "$PERF" != 0 ]; then
        "$ROOT/bin/qs-perf" --children "$pid" "$PERF"
    fi
    kill "$pid" 2>/dev/null
done
exit $fail
