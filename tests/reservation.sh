#!/bin/bash
# P1-02: the backend publishes its panels' exclusive zones to yabai.
#
#   bash tests/reservation.sh          (QS_BINARY overrides the binary, as in qs-test)
#
# Captures yabai's external_bar and the four paddings first and restores all
# five in a trap, whatever happens: this test moves the user's windows.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/quickshell-$UID}"
export QML2_IMPORT_PATH="$ROOT/shims${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"

BINARY="${QS_BINARY:-$ROOT/bin/qs}"
QML="$ROOT/tests/reservation.qml"
LOG=/tmp/qs-test-reservation.log

command -v yabai >/dev/null || { echo "  SKIP  yabai not installed"; exit 0; }

# Parallel arrays: /bin/bash is 3.2 and has no associative ones.
KEYS=(external_bar top_padding bottom_padding left_padding right_padding)
SAVED=()
for k in "${KEYS[@]}"; do SAVED+=("$(yabai -m config "$k" 2>/dev/null)"); done
echo "  saved: $(for i in "${!KEYS[@]}"; do printf '%s=%s ' "${KEYS[$i]}" "${SAVED[$i]}"; done)"

PID=""
restore() {
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    for i in "${!KEYS[@]}"; do yabai -m config "${KEYS[$i]}" "${SAVED[$i]}" 2>/dev/null; done
    echo "  restored: external_bar=$(yabai -m config external_bar)"
}
trap restore EXIT

PID="$("$ROOT/bin/qs-test" "$QML" --binary "$BINARY" --log "$LOG" --shell)" \
    || { echo "probe failed to start; see $LOG" >&2; exit 1; }

ask() { "$BINARY" -p "$QML" ipc call probe "$@" 2>/dev/null | tr -d '\r\n'; }

# yabai is written 100 ms after the change settles, by a detached process.
settle() { sleep 0.6; }

pass=0; fail=0
check() {  # label expected actual
    if [ "$2" = "$3" ]; then printf '  PASS  %-40s %s\n' "$1" "$3"; pass=$((pass+1))
    else printf '  FAIL  %-40s got %-12s want %s\n' "$1" "$3" "$2"; fail=$((fail+1)); fi
}

settle
check "top panel: Reservation" "40,0,0,0" "$(ask zones)"
check "top panel: yabai external_bar" "all:40:0" "$(yabai -m config external_bar)"

ask edge bottom >/dev/null; settle
check "bottom panel: Reservation" "0,40,0,0" "$(ask zones)"
check "bottom panel: yabai external_bar" "all:0:40" "$(yabai -m config external_bar)"

ask shown false >/dev/null; sleep 0.3; settle
check "hidden panel: Reservation" "0,0,0,0" "$(ask zones)"
check "hidden panel: yabai external_bar" "all:0:0" "$(yabai -m config external_bar)"

ask shown true >/dev/null; ask edge top >/dev/null; settle
check "shown again at the top: yabai" "all:40:0" "$(yabai -m config external_bar)"

/usr/bin/python3 - "$LOG" <<'PY'
import sys
for line in open(sys.argv[1], errors='replace'):
    if 'cocoa: reservation' in line: print('  log:', line.rstrip()[-70:])
PY
echo "  $pass passed, $fail failed"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
