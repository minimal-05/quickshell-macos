#!/bin/bash
# Acceptance run for the yabai-signal path behind Quickshell.Hyprland and
# Quickshell.Wayland (bin/qs-yabai-signals, Quickshell.Cocoa.FileWatcher).
#
#   tests/yabai-events.sh              full run, including one Space switch and back
#   YE_NO_SPACE=1 tests/yabai-events.sh   skip the Space switch
#   YE_IDLE=15 tests/yabai-events.sh      seconds to watch an idle instance (default 15)
#
# Asserts: the probe populates; an idle instance spawns no yabai in YE_IDLE s;
# `yabai -m signal --list` holds each qs_* label exactly once after the probe
# (which installs them) ran install again; a Space switch reaches
# Hyprland.focusedWorkspace within 50 ms of yabai's signal (measured as the
# probe's Date.now() at the change minus the signal file's mtime) and costs
# one space query plus one window query; hl.dsp.global() reaches a
# GlobalShortcut in-process; HyprlandToplevel.wayland resolves.
#
# The signals are removed afterwards only if none were registered before the
# run: a live shell on this branch owns them otherwise.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/quickshell-$UID}"
BINARY="${QS_BINARY:-$ROOT/bin/qs}"
QML="$ROOT/tests/_probe_hyprland.qml"
IDLE="${YE_IDLE:-15}"
SIG="$XDG_RUNTIME_DIR/quickshell/yabai/space_changed"

fail=0
ok()   { printf '  PASS  %-40s %s\n' "$1" "$2"; }
bad()  { printf '  FAIL  %-40s %s\n' "$1" "$2"; fail=1; }
ipc()  { "$BINARY" -p "$QML" ipc call hyprland "$@" 2>/dev/null | tr -d '\r'; }
qs_labels() { yabai -m signal --list 2>/dev/null | /usr/bin/python3 -c 'import json,sys; [print(s["label"]) for s in json.load(sys.stdin) if str(s.get("label","")).startswith("qs_")]'; }
count() { grep -c . || true; }

had_before="$(qs_labels | count)"

pid="$("$ROOT/bin/qs-test" "$QML" --binary "$BINARY" --shell)" || { echo "  FAIL  probe did not start"; exit 1; }
trap 'kill "$pid" 2>/dev/null' EXIT
sleep 3

got="$(ipc check)"; [ "$got" = ok ] && ok "populated" "$got" || bad "populated" "$got"
got="$(ipc global)"; [ "$got" = pressed ] && ok "hl.dsp.global in-process" "$got" || bad "hl.dsp.global in-process" "$got"
got="$(ipc wayland)"; [ "$got" != none ] && ok "HyprlandToplevel.wayland" "$got" || bad "HyprlandToplevel.wayland" "$got"

# Idempotence: the probe installed once at start; install again and count.
"$ROOT/bin/qs-yabai-signals" install >/dev/null
dups="$(qs_labels | sort | uniq -d | count)"
n="$(qs_labels | count)"
[ "$dups" = 0 ] && [ "$n" -ge 21 ] && ok "signals registered once" "$n labels, 0 duplicates" || bad "signals registered once" "$n labels, $dups duplicates"

# "Idle" on a desktop someone is using still sees events (this terminal's
# title changes as commands run), so the assertion is that every yabai spawn
# is accounted for by a query and every query by a touched signal file —
# nothing runs on a timer.
q0="$(ipc queries)"
t0="$(/usr/bin/python3 -c 'import time; print(time.time())')"
spawns="$("$ROOT/bin/qs-spawns" "$pid" "$IDLE")"
yabai_n="$(printf '%s\n' "$spawns" | awk '$2 == "yabai" {print $1}')"
[ -z "$yabai_n" ] && yabai_n=0
q1="$(ipc queries)"
touched="$(/usr/bin/python3 -c "import os,sys; d=os.path.dirname('$SIG'); print(sum(1 for f in os.listdir(d) if os.stat(os.path.join(d,f)).st_mtime >= float('$t0')))")"
dq="$(( ${q1%% *} - ${q0%% *} + ${q1##* } - ${q0##* } ))"
if [ "$yabai_n" -le "$dq" ] && { [ "$dq" = 0 ] || [ "$touched" -ge 1 ]; }; then
    ok "idle ${IDLE}s: nothing periodic" "$yabai_n yabai for $dq queries, $touched signal files touched"
else
    bad "idle ${IDLE}s: nothing periodic" "$yabai_n yabai for $dq queries, $touched signal files touched"
fi

if [ "${YE_NO_SPACE:-0}" != 1 ]; then
    cur="$(yabai -m query --spaces --space | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["index"])')"
    other="$(yabai -m query --spaces | /usr/bin/python3 -c "import json,sys; print(next(s['index'] for s in json.load(sys.stdin) if s['index'] != $cur))")"
    q0="$(ipc queries)"
    yabai -m space --focus "$other"; sleep 0.6
    a="$(ipc focusedAt)"; m="$(/usr/bin/stat -f %Fm "$SIG")"; f="$(ipc focused)"
    yabai -m space --focus "$cur"; sleep 0.6
    a2="$(ipc focusedAt)"; m2="$(/usr/bin/stat -f %Fm "$SIG")"; f2="$(ipc focused)"
    q1="$(ipc queries)"
    lat="$(/usr/bin/python3 -c "print(round(float('$a') - float('$m') * 1000, 1))")"
    lat2="$(/usr/bin/python3 -c "print(round(float('$a2') - float('$m2') * 1000, 1))")"
    [ "$f" = "$other" ] && [ "$f2" = "$cur" ] && ok "focusedWorkspace follows the switch" "$cur -> $other -> $cur" || bad "focusedWorkspace follows the switch" "got $f then $f2"
    slow="$(/usr/bin/python3 -c "print(1 if max($lat, $lat2) > 50 else 0)")"
    [ "$slow" = 0 ] && ok "latency < 50 ms" "${lat} ms, ${lat2} ms" || bad "latency < 50 ms" "${lat} ms, ${lat2} ms"
    # one --spaces and one --windows per switch; a second window query is
    # allowed for a burst that outlives the 10 ms settle window
    ds="$(( ${q1%% *} - ${q0%% *} ))"; dw="$(( ${q1##* } - ${q0##* } ))"
    [ "$ds" -le 2 ] && [ "$dw" -le 4 ] && [ "$dw" -ge 2 ] && ok "queries per switch" "spaces +$ds, windows +$dw for 2 switches" || bad "queries per switch" "spaces +$ds, windows +$dw for 2 switches"
fi

kill "$pid" 2>/dev/null; trap - EXIT
if [ "$had_before" = 0 ]; then
    "$ROOT/bin/qs-yabai-signals" remove >/dev/null
    [ "$(qs_labels | count)" = 0 ] && ok "signals removed after the run" "" || bad "signals removed after the run" "$(qs_labels | tr '\n' ' ')"
else
    echo "  (qs_* signals were registered before the run; left in place)"
fi
exit $fail
