#!/bin/bash
# PF-06: a hidden panel releases its GPU swapchain, and renders again on show.
#
#   bash tests/swapchain.sh            (QS_BINARY overrides the binary, as in qs-test)
#
# Reads `vmmap --summary` on the probe with its full-height panel open, then
# closed for longer than the release timer (270 ms close animation + 1 s):
# the IOSurface total must drop back to (about) the idle figure. Then re-opens
# it and asserts frameSwapped keeps counting.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/quickshell-$UID}"
export QML2_IMPORT_PATH="$ROOT/shims${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"

BINARY="${QS_BINARY:-$ROOT/bin/qs}"
QML="$ROOT/tests/swapchain.qml"
LOG=/tmp/qs-test-swapchain.log

PID="$("$ROOT/bin/qs-test" "$QML" --binary "$BINARY" --log "$LOG" --shell)" \
    || { echo "probe failed to start; see $LOG" >&2; exit 1; }
stop() { kill "$PID" 2>/dev/null; }
trap stop EXIT

ask() { "$BINARY" -p "$QML" ipc call probe "$1" 2>/dev/null | tr -d '\r\n'; }

# "IOSurface  120.0M ..." / "IOAccelerator 8.0M": the RESIDENT column of
# vmmap's summary, in MB (vmmap prints K/M/G suffixes).
gpu_mb() {
    vmmap --summary "$PID" 2>/dev/null | /usr/bin/python3 -c '
import re, sys
want = {"IOSurface": 0.0, "IOAccelerator": 0.0}
for line in sys.stdin:
    m = re.match(r"^(IOSurface|IOAccelerator)\s+(\S+)\s+(\S+)\s+(\S+)", line)
    if not m: continue
    v, unit = re.match(r"([\d.]+)([KMG]?)", m.group(3)).groups()
    want[m.group(1)] = float(v) * {"": 1/1024/1024, "K": 1/1024, "M": 1, "G": 1024}[unit]
print("IOSurface=%.1fM IOAccelerator=%.1fM" % (want["IOSurface"], want["IOAccelerator"]))
'
}
mb_of() { echo "$1" | sed -n 's/.*IOSurface=\([0-9.]*\)M.*/\1/p'; }

pass=0; fail=0
check() {  # label expected actual
    if [ "$2" = "$3" ]; then printf '  PASS  %-40s %s\n' "$1" "$3"; pass=$((pass+1))
    else printf '  FAIL  %-40s got %-9s want %s\n' "$1" "$3" "$2"; fail=$((fail+1)); fi
}

sleep 0.5
idle="$(gpu_mb)"; echo "  idle (never shown):   $idle"

ask open >/dev/null; sleep 1.2
f1="$(ask frames)"
shown="$(gpu_mb)"; echo "  open (full height):   $shown  frames=$f1"
check "panel rendered while open" 1 "$([ "${f1:-0}" -gt 0 ] && echo 1 || echo 0)"

ask close >/dev/null; sleep 2
hidden="$(gpu_mb)"; echo "  closed:               $hidden  $(ask state)"
# Released means back within 8 MB of idle (one drawable's worth of slack).
check "IOSurface released on hide" 1 "$(/usr/bin/python3 -c "import sys; print(1 if $(mb_of "$hidden") <= $(mb_of "$idle") + 8 else 0)")"

ask open >/dev/null; sleep 1.2
f2="$(ask frames)"
reopened="$(gpu_mb)"; echo "  re-opened:            $reopened  frames=$f2"
check "panel renders again after re-show" 1 "$([ "${f2:-0}" -gt "${f1:-0}" ] && echo 1 || echo 0)"
check "re-shown panel is visible" "visible=true backing=true" "$(ask state)"

ask close >/dev/null; sleep 2
hidden2="$(gpu_mb)"; echo "  closed again:         $hidden2"
check "released again on second hide" 1 "$(/usr/bin/python3 -c "import sys; print(1 if $(mb_of "$hidden2") <= $(mb_of "$idle") + 8 else 0)")"

# animate: false -- the backing window is gone as soon as visible goes false,
# where an animated panel stays mapped for the 270 ms close.
"$BINARY" -p "$QML" ipc call probe instantToggle true >/dev/null; sleep 0.3
check "animate=false panel hides at once" "backing=false" "$("$BINARY" -p "$QML" ipc call probe instantToggle false | tr -d '\r\n')"
ask open >/dev/null; sleep 0.5
ask close >/dev/null
check "animated panel still mapped right after hide" "backing=true" "$(ask state | sed 's/.*backing/backing/')"
sleep 0.5
check "animated panel unmapped after the close" "visible=false backing=false" "$(ask state)"

echo "  $pass passed, $fail failed"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
