#!/bin/bash
# The Pipewire shim on its CoreAudio backend, checked against the system's own
# tools in both directions: what the probe reports must match osascript and
# SwitchAudioSource, a write through the node API must be visible to osascript
# at once, and a change made by osascript must land on the node through the
# HAL listener (no poller exists any more) within 500 ms.
#
#   tests/native-audio.sh              run the checks
#   PERF=40 tests/native-audio.sh      also print qs-perf --children over 40 s
#                                      (target: 0 osascript/SwitchAudioSource)
#   QS_BINARY=.../Quickshell.app/Contents/MacOS/quickshell   another build
#
# The user's output volume, mute state and input volume are captured first and
# put back exactly at the end, whatever happened in between.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${QS_BINARY:-$ROOT/bin/qs}"
QML="$ROOT/tests/_probe_audio.qml"
PERF="${PERF:-0}"
export PATH="$ROOT/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/quickshell-$UID}"

fail=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }
ipc() { "$BINARY" -p "$QML" ipc call audio "$@" 2>/dev/null | tr -d '\r'; }
now_ms() { /usr/bin/python3 -c 'import time; print(int(time.time() * 1000))'; }
near() { /usr/bin/python3 -c 'import sys; sys.exit(0 if abs(int(sys.argv[1]) - int(sys.argv[2])) <= 1 else 1)' "$1" "$2" 2>/dev/null; }
# Poll the probe until `fn` answers `want`; prints the milliseconds it took.
wait_ipc() {  # $1 fn, $2 want, $3 budget ms
    local t0 t1 got; t0="$(now_ms)"
    while :; do
        got="$(ipc "$1")"; t1="$(now_ms)"
        [ "$got" = "$2" ] && { echo "$((t1 - t0))"; return 0; }
        [ $((t1 - t0)) -gt "$3" ] && { echo "$((t1 - t0))"; return 1; }
        sleep 0.05
    done
}

command -v SwitchAudioSource >/dev/null || { echo "  skip  SwitchAudioSource not installed (brew install switchaudio-osx)"; exit 0; }

# --- capture and guarantee restore --------------------------------------------
settings="$(osascript -e 'get volume settings')"
OUT0="$(sed -n 's/.*output volume:\([0-9]*\).*/\1/p' <<<"$settings")"
IN0="$(sed -n 's/.*input volume:\([0-9]*\).*/\1/p' <<<"$settings")"
MUTED0="$(sed -n 's/.*output muted:\([a-z]*\).*/\1/p' <<<"$settings")"
[ -n "$OUT0" ] && [ -n "$MUTED0" ] || { echo "  FAIL  could not parse: $settings"; exit 1; }
echo "  captured: output $OUT0%, muted $MUTED0, input ${IN0:-?}%"

pid=""
restore() {
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    osascript -e "set volume output volume $OUT0" -e "set volume output muted $MUTED0" >/dev/null
    [ -n "$IN0" ] && osascript -e "set volume input volume $IN0" >/dev/null
    local after; after="$(osascript -e 'get volume settings')"
    if [ "$after" = "$settings" ]; then printf '  PASS  restored: %s\n' "$after"
    else printf '  FAIL  restore mismatch\n        before %s\n        after  %s\n' "$settings" "$after"; fail=1; fi
}
trap restore EXIT

# --- start ----------------------------------------------------------------------
pid="$("$ROOT/bin/qs-test" "$QML" --binary "$BINARY" --shell)" || { bad "probe did not start"; exit 1; }
sleep 0.5

got="$(ipc check)"; [ "$got" = ok ] && ok "check == ok" || bad "check == $got"

want="$(SwitchAudioSource -c -t output)"; got="$(ipc sink)"
[ "$got" = "$want" ] && ok "default sink '$got' == SwitchAudioSource -c" || bad "default sink '$got', SwitchAudioSource says '$want'"
want="$(SwitchAudioSource -c -t input)"; got="$(ipc source)"
[ "$got" = "$want" ] && ok "default source '$got' == SwitchAudioSource -c -t input" || bad "default source '$got', SwitchAudioSource says '$want'"

want="$(SwitchAudioSource -a -t output | sort)"; got="$(ipc sinks | sort)"
[ "$got" = "$want" ] && ok "sink list == SwitchAudioSource -a ($(wc -l <<<"$got" | tr -d ' ') devices)" || bad "sink list differs: got [$(tr '\n' '|' <<<"$got")] want [$(tr '\n' '|' <<<"$want")]"
want="$(SwitchAudioSource -a -t input | sort)"; got="$(ipc sources | sort)"
[ "$got" = "$want" ] && ok "source list == SwitchAudioSource -a -t input" || bad "source list differs: got [$(tr '\n' '|' <<<"$got")] want [$(tr '\n' '|' <<<"$want")]"

got="$(ipc volume)"; near "$got" "$OUT0" && ok "volume $got == osascript $OUT0 (+-1)" || bad "volume $got, osascript says $OUT0"
got="$(ipc muted)"; [ "$got" = "$MUTED0" ] && ok "muted $got == osascript" || bad "muted $got, osascript says $MUTED0"
if [ -n "$IN0" ]; then
    got="$(ipc inputVolume)"; near "$got" "$IN0" && ok "input volume $got == osascript $IN0 (+-1)" || bad "input volume $got, osascript says $IN0"
fi

# --- node -> HAL: a write through the shim is visible to osascript at once ----
if [ "$OUT0" -ge 50 ]; then t1=$((OUT0 - 13)); t2=$((OUT0 - 7)); else t1=$((OUT0 + 13)); t2=$((OUT0 + 7)); fi
got="$(ipc setVolume "$t1")"
seen="$(osascript -e 'output volume of (get volume settings)')"
near "$seen" "$t1" && ok "setVolume $t1 -> osascript sees $seen" || bad "setVolume $t1 -> node says $got, osascript sees $seen"

# --- HAL -> node: an osascript change lands through the listener, no poll ----
ev0="$(ipc events)"
osascript -e "set volume output volume $t2"
if ms="$(wait_ipc volume "$t2" 500)"; then ok "osascript set $t2 -> node volume $t2 after ${ms} ms (limit 500)"
else bad "osascript set $t2 -> node still $(ipc volume) after ${ms} ms"; fi
ev1="$(ipc events)"
[ "${ev1%% *}" -gt "${ev0%% *}" ] && ok "volumeChanged fired (${ev0%% *} -> ${ev1%% *} events)" || bad "no volumeChanged event ($ev0 -> $ev1)"

# --- mute, both directions -----------------------------------------------------
got="$(ipc setMuted true)"
seen="$(osascript -e 'output muted of (get volume settings)')"
[ "$seen" = true ] && ok "setMuted true -> osascript sees muted" || bad "setMuted true -> node $got, osascript sees $seen"
osascript -e 'set volume output muted false'
if ms="$(wait_ipc muted false 500)"; then ok "osascript unmute -> node muted false after ${ms} ms"
else bad "osascript unmute -> node still muted after ${ms} ms"; fi

# --- input volume through the listener -----------------------------------------
if [ -n "$IN0" ] && [ "$(ipc source)" != "" ]; then
    if [ "$IN0" -ge 50 ]; then t3=$((IN0 - 11)); else t3=$((IN0 + 11)); fi
    osascript -e "set volume input volume $t3"
    if ms="$(wait_ipc inputVolume "$t3" 500)"; then ok "osascript set input $t3 -> node after ${ms} ms"
    else bad "osascript set input $t3 -> node still $(ipc inputVolume) after ${ms} ms"; fi
fi

if [ "$PERF" != 0 ]; then
    "$ROOT/bin/qs-perf" --children "$pid" "$PERF"
fi
exit $fail
