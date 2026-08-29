#!/bin/bash
# P0-01 acceptance: a GlobalShortcut fires from a real key chord.
#
#   bash tests/hotkeys.sh                  (QS_BINARY overrides bin/qs)
#
# Starts tests/_probe_hotkeys.qml with a private chord table (QS_SHORTCUTS) and
# a private skhdrc (SKHD_RC), posts the chords with CGEvent from python (which
# needs Accessibility, as bin/ydotool does), and asserts through the probe's
# IPC that pressed/released arrived, that a held key reports the press before
# the release, that a chord skhd binds is left alone, that a bare modifier is
# refused, and that the gs_* IPC route still works.
#
# The chords are ctrl+alt+cmd+shift+{z,y,q}: no app binds a four-modifier
# letter, and the user's own skhdrc is checked for them first and the run
# skipped if it binds any. (F17-F19 would be cleaner still, but a synthetic
# press of those never reaches a hot key on macOS 15; a letter does.)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export QS_BINARY="${QS_BINARY:-$ROOT/bin/qs}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/quickshell-$UID}"
export QML2_IMPORT_PATH="$ROOT/shims${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
PROBE="$ROOT/tests/_probe_hotkeys.qml"
LOG="${TMPDIR:-/tmp}/qs-test-_probe_hotkeys.log"

RC="${HOME}/.config/skhd/skhdrc"
if [ -f "$RC" ] && /usr/bin/python3 -c "import re,sys; sys.exit(0 if re.search(r'^[^#:]*shift[^#:]*-\s*[zyq]\s*:', open(sys.argv[1]).read(), re.M|re.I) else 1)" "$RC"; then
    echo "  SKIP  $RC binds shift-z/y/q; the probe chords would collide"; exit 0
fi

TMP="$(mktemp -d /tmp/qs-hotkeys.XXXXXX)"
cat >"$TMP/shortcuts.json" <<JSON
{"quickshell:qstest": "ctrl+alt+cmd+shift+z", "quickshell:qsheld": "ctrl+alt+cmd+shift+y",
 "quickshell:qsskhd": "ctrl+alt+cmd+shift+q", "quickshell:qsmod": "cmd", "quickshell:qsbad": "ctrl+nosuchkey"}
JSON
printf '# private skhdrc for the probe\nctrl + alt + cmd + shift - q : true\n' >"$TMP/skhdrc"
export QS_SHORTCUTS="$TMP/shortcuts.json" SKHD_RC="$TMP/skhdrc"

cat >"$TMP/key.py" <<'PY'
import ctypes, sys, time
cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
cg.CGEventSetFlags.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
cg.CFRelease.argtypes = [ctypes.c_void_p]
SHIFT, CTRL, ALT, CMD = 1 << 17, 1 << 18, 1 << 19, 1 << 20
MODS = [(56, SHIFT), (59, CTRL), (58, ALT), (55, CMD)]   # shift, control, option, command

def post(vk, down, flags):
    e = cg.CGEventCreateKeyboardEvent(None, vk, down)
    cg.CGEventSetFlags(e, flags)
    cg.CGEventPost(0, e)          # kCGHIDEventTap
    cg.CFRelease(e)
    time.sleep(0.02)

vk, action = int(sys.argv[1]), sys.argv[2]
flags = 0
if action in ("down", "tap"):
    for mvk, bit in MODS:
        flags |= bit
        post(mvk, True, flags)
    post(vk, True, flags)
if action in ("up", "tap"):
    flags = SHIFT | CTRL | ALT | CMD
    post(vk, False, flags)
    for mvk, bit in reversed(MODS):
        flags &= ~bit
        post(mvk, False, flags)
PY
key() { /usr/bin/python3 "$TMP/key.py" "$@"; }

PID="$("$ROOT/bin/qs-test" "$PROBE" --shell)" || { echo "FAIL: probe did not start"; rm -rf "$TMP"; exit 1; }
trap 'kill "$PID" 2>/dev/null; rm -rf "$TMP"' EXIT
fails=0
ipc() { "$QS_BINARY" -p "$PROBE" ipc call hotkeys "$@" 2>/dev/null | tr -d '\r'; }
eq() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s\n        got:  %s\n        want: %s\n' "$1" "$2" "$3"; fails=$((fails+1)); fi; }
settle() { for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(ipc events)" = "$1" ] && return; sleep 0.1; done; }

eq "chord(qstest) from the table"        "$(ipc chord qstest)" "ctrl+alt+cmd+shift+z"
eq "chord(qsskhd) left to skhd"          "$(ipc chord qsskhd)" ""
eq "chord(qsmod) bare modifier unbound"  "$(ipc chord qsmod)" ""
eq "chord(qsbad) unparsable unbound"     "$(ipc chord qsbad)" ""
eq "bindings lists qsheld"               "$(ipc bindings | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["quickshell:qsheld"])')" "ctrl+alt+cmd+shift+y"
eq "log: skhd overlap reported"          "$(grep -c 'left to skhd' "$LOG")" "1"
eq "log: bare modifier reported"         "$(grep -c 'qsmod.*bare modifier' "$LOG")" "1"
eq "log: unknown key reported"           "$(grep -c 'unknown key' "$LOG")" "1"

key 6 tap; sleep 0.5
# Two instances of one name: both see the press; their order is connection order, not asserted.
eq "ctrl+alt+cmd+shift+z tap: press and release, both instances" "$(ipc events | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')" "qstest2:down qstest:down qstest:up "
eq "pressed count" "$(ipc pressed)" "1"
eq "released count" "$(ipc released)" "1"

ipc reset >/dev/null
key 16 down; settle "qsheld:down"
eq "ctrl+alt+cmd+shift+y held: press arrives alone" "$(ipc events)" "qsheld:down"
key 16 up; settle "qsheld:down qsheld:up"
eq "release arrives on key up" "$(ipc events)" "qsheld:down qsheld:up"

ipc reset >/dev/null
key 12 tap; sleep 0.5
eq "ctrl+alt+cmd+shift+q (skhd's) does not fire" "$(ipc events)" ""

ipc reset >/dev/null
"$QS_BINARY" -p "$PROBE" ipc call gs_quickshell_qsheld press >/dev/null 2>&1; settle "qsheld:down qsheld:up"
eq "gs_quickshell_qsheld press over IPC still works" "$(ipc events)" "qsheld:down qsheld:up"

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED (log $LOG)"; exit 1; }
