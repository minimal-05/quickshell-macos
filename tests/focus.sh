#!/bin/bash
# P1-03: a focusable panel takes activation on show and hands it back on hide.
#
#   bash tests/focus.sh            (QS_BINARY overrides the binary, as in qs-test)
#
# The previously frontmost application is recorded with `lsappinfo front`
# before the probe starts; after `probe hide` it must be frontmost again within
# 500 ms. Whatever happens, the trap puts it back in front and kills only the
# instance this script started.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/quickshell-$UID}"
export QML2_IMPORT_PATH="$ROOT/shims${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
# A throwaway instance must not push its panel's zone into yabai.
export QS_NO_YABAI_ZONES=1

BINARY="${QS_BINARY:-$ROOT/bin/qs}"
QML="$ROOT/tests/focus.qml"
LOG=/tmp/qs-test-focus.log

front_pid() { lsappinfo info -only pid "$(lsappinfo front)" | sed -n 's/.*"pid"=\([0-9]*\).*/\1/p'; }
front_bundle() { lsappinfo info -only bundleid "$(lsappinfo front)" | sed -n 's/.*"CFBundleIdentifier"="\([^"]*\)".*/\1/p'; }
now_ms() { /usr/bin/python3 -c 'import time; print(int(time.time()*1000))'; }

ORIG_PID="$(front_pid)"
ORIG_BUNDLE="$(front_bundle)"
echo "  frontmost at start: pid $ORIG_PID ($ORIG_BUNDLE)"

# The application the panel must hand activation back to. The user's own
# frontmost app when it is an ordinary one; Finder when it is a shell instance
# (another test's probe, or the live shell), because `open -b
# org.quickshell.shell` would launch one of the several Quickshell.app copies
# that share that id rather than raise the running one.
if [ -n "$ORIG_BUNDLE" ] && [ "$ORIG_BUNDLE" != org.quickshell.shell ]; then
    TARGET_BUNDLE="$ORIG_BUNDLE"
else
    TARGET_BUNDLE=com.apple.finder
fi

PID="$("$ROOT/bin/qs-test" "$QML" --binary "$BINARY" --log "$LOG" --shell)" \
    || { echo "probe failed to start; see $LOG" >&2; exit 1; }

restore() {
    kill "$PID" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$PID" 2>/dev/null
    if [ "$(front_pid)" != "$ORIG_PID" ] && [ -n "$ORIG_BUNDLE" ] \
        && [ "$ORIG_BUNDLE" != org.quickshell.shell ]; then
        open -b "$ORIG_BUNDLE" 2>/dev/null
    fi
}
trap restore EXIT

ask() { "$BINARY" -p "$QML" ipc call probe "$1" 2>/dev/null | tr -d '\r\n'; }

pass=0; fail=0
check() {  # label expected actual
    if [ "$2" = "$3" ]; then printf '  PASS  %-38s %s\n' "$1" "$3"; pass=$((pass+1))
    else printf '  FAIL  %-38s got %-9s want %s\n' "$1" "$3" "$2"; fail=$((fail+1)); fi
}

# Wait until front_pid equals $1, at most $2 ms; prints the elapsed ms.
wait_front() {
    local want="$1" limit="$2" start elapsed
    start="$(now_ms)"
    while :; do
        elapsed=$(( $(now_ms) - start ))
        [ "$(front_pid)" = "$want" ] && { echo "$elapsed"; return 0; }
        [ "$elapsed" -ge "$limit" ] && { echo "$elapsed"; return 1; }
        sleep 0.05
    done
}

# Put a known application in front to hand back to. Starting the probe must
# not have left the probe itself there: it is an accessory from the moment its
# (hidden) panel exists, and gives the activation Qt takes at startup straight
# back. Only a note when the front app is not the one recorded, though: on a
# desktop where other test instances start and quit, an app quitting hands
# activation to whichever was active most recently.
sleep 0.5
[ "$(front_pid)" != "$PID" ] || echo "  note: probe was front after start (Qt startup activation not released?)"
open -b "$TARGET_BUNDLE" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do [ "$(front_bundle)" = "$TARGET_BUNDLE" ] && break; sleep 0.25; done
PREV_PID="$(front_pid)"; PREV_BUNDLE="$(front_bundle)"
check "known app in front before open ($PREV_BUNDLE)" "$TARGET_BUNDLE" "$PREV_BUNDLE"

ask open >/dev/null
t="$(wait_front "$PID" 1500)"; rc=$?
check "show: probe frontmost (${t} ms)" 0 "$rc"
sleep 0.2
check "show: panel window active" true "$(ask active)"

ask close >/dev/null
t="$(wait_front "$PREV_PID" 500)"; rc=$?
check "hide: previous app front within 500 ms (${t} ms)" 0 "$rc"
sleep 0.2
check "hide: panel window inactive" false "$(ask active)"

/usr/bin/python3 - "$LOG" <<'PY'
import sys
for line in open(sys.argv[1], errors='replace'):
    if 'cocoa: activation' in line: print('  log:', line.rstrip()[-80:])
PY

echo "  $pass passed, $fail failed"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
