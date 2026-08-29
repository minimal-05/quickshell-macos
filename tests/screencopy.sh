#!/bin/bash
# P1-05 acceptance: ScreencopyView on ScreenCaptureKit, in-process.
#
#   bash tests/screencopy.sh            (QS_BINARY overrides bin/qs)
#
# Starts tests/_probe_screencopy.qml as a throwaway instance (it captures a
# still of the first screen at load) and asserts through the probe's IPC.
# Which branch runs depends on whether the bundle under test holds the Screen
# Recording grant; the script reports which one it took.
#
#   permission  status == "permission", hasContent == false, the instance is
#               still alive, the warning was logged exactly once even after a
#               second source, and no `screencapture` child was spawned.
#   ok          hasContent == true and sourceSize is the screen's pixel size;
#               a window source's sourceSize matches its yabai frame at the
#               screen scale (within 2 px); live: true delivers >= 2 frames in
#               1 s; stop() ends the stream; still no `screencapture` child.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${QS_BINARY:-$ROOT/bin/qs}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/quickshell-$UID}"
export QML2_IMPORT_PATH="$ROOT/shims${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
PROBE="$ROOT/tests/_probe_screencopy.qml"
LOG="${TMPDIR:-/tmp}/qs-test-screencopy.log"

PID="$("$ROOT/bin/qs-test" "$PROBE" --binary "$BINARY" --log "$LOG" --shell)" || { echo "  FAIL  probe did not start (log $LOG)"; exit 1; }
trap 'kill "$PID" 2>/dev/null' EXIT
fails=0
ipc() { "$BINARY" -p "$PROBE" ipc call screencopy "$@" 2>/dev/null | tr -d '\r\n'; }
check() { # name, expected, actual
    if [ "$2" = "$3" ]; then printf '  PASS  %-44s %s\n' "$1" "$3"
    else printf '  FAIL  %-44s got %s want %s\n' "$1" "$3" "$2"; fails=$((fails+1)); fi
}
alive() { kill -0 "$PID" 2>/dev/null && echo alive || echo dead; }
settle() { # wait up to $1 s for status to leave "pending"
    for _ in $(seq 1 $(( $1 * 10 ))); do
        s="$(ipc status)"
        [ "$s" != "pending" ] && [ -n "$s" ] && return 0
        sleep 0.1
    done
    return 1
}
count_log() { /usr/bin/python3 -c 'import sys; print(open(sys.argv[1], errors="replace").read().count(sys.argv[2]))' "$LOG" "$1"; }
# One spawn histogram for the whole run; screencapture must never appear in it.
"$ROOT/bin/qs-perf" --children "$PID" 4 > "${TMPDIR:-/tmp}/qs-screencopy-children.txt" 2>&1 &
PERFPID=$!

settle 5 || echo "  WARN  status still pending after 5 s"
status="$(ipc status)"
check "instance alive after first capture" alive "$(alive)"

case "$status" in
    permission)
        echo "  -- permission path (${QS_SCREENCOPY_DENY:+forced by QS_SCREENCOPY_DENY; }Screen Recording treated as not granted)"
        check "status" permission "$status"
        check "hasContent" false "$(ipc hasContent)"
        check "frames" 0 "$(ipc frames)"
        check "sourceSize empty" "0x0" "$(ipc sourceSize)"
        check "permission warning logged once" 1 "$(count_log 'Screen Recording is not granted')"
        # A second source, live, must degrade the same way and not log again.
        wid=none
        for _ in $(seq 1 30); do wid="$(ipc firstWindow)"; [ "$wid" != none ] && break; sleep 0.1; done
        if [ "$wid" != none ]; then
            ipc window "$wid" >/dev/null; ipc live true >/dev/null
            settle 5
            check "window source: status" permission "$(ipc status)"
            check "window source: hasContent" false "$(ipc hasContent)"
        fi
        check "permission warning still logged once" 1 "$(count_log 'Screen Recording is not granted')"
        check "instance alive" alive "$(alive)"
        echo "  -- not exercised: still content, window sourceSize, live frames (need the TCC grant)"
        ;;
    ok)
        echo "  -- capture path (Screen Recording granted)"
        check "screen still: status" ok "$status"
        check "screen still: hasContent" true "$(ipc hasContent)"
        check "screen still: sourceSize == screen pixels" "$(ipc screenInfo | cut -d@ -f1)" "$(ipc sourceSize)"
        check "screen still: exactly one frame" 1 "$(ipc frames)"

        # A real window on the current space, straight from yabai (the shim's
        # list order puts transient sheets first). "wid frame_w frame_h".
        dpr="$(ipc screenInfo | cut -d@ -f2)"
        pick="$(yabai -m query --windows 2>/dev/null | /usr/bin/python3 -c '
import json,sys
d=float(sys.argv[1])
for w in json.load(sys.stdin):
    if w.get("is-visible") and not w.get("is-minimized") and w.get("app") != "quickshell" and w["frame"]["w"] >= 200:
        print(w["id"], round(w["frame"]["w"]*d), round(w["frame"]["h"]*d)); break' "$dpr")"
        if [ -z "$pick" ]; then
            echo "  SKIP  no visible window from yabai; window and live checks skipped"
        else
            set -- $pick; wid=$1; want="$2 $3"
            # The ToplevelManager shim polls yabai once a second; wait for it to list the window.
            r=""
            for _ in $(seq 1 30); do r="$(ipc window "$wid")"; [ "$r" = ok ] && break; sleep 0.1; done
            check "window $wid known to ToplevelManager" ok "$r"
            settle 5
            check "window $wid still: status" ok "$(ipc status)"
            check "window $wid still: hasContent" true "$(ipc hasContent)"
            got="$(ipc sourceSize | tr x " ")"
            near="$(/usr/bin/python3 -c '
import sys
a=list(map(int,sys.argv[1].split())); b=list(map(int,sys.argv[2].split()))
print("near" if len(a)==2 and len(b)==2 and all(abs(x-y)<=2 for x,y in zip(a,b)) else "far")' "$want" "$got")"
            check "window $wid: sourceSize ~ yabai frame*dpr ($want)" near "$near"

            # SCK only emits frames that changed, so a static window yields the
            # first frame plus whatever redraws in the window; two is the floor.
            ipc live true >/dev/null
            sleep 1.5
            frames="$(ipc frames)"
            check "live: status" ok "$(ipc status)"
            check "live: >= 2 frames in ~1 s ($frames)" yes "$([ "${frames:-0}" -ge 2 ] 2>/dev/null && echo yes || echo no)"

            ipc hidePanel >/dev/null; sleep 0.3
            check "hidden window pauses the stream" paused "$(ipc status)"
            ipc showPanel >/dev/null
            for _ in $(seq 1 50); do [ "$(ipc status)" = ok ] && break; sleep 0.1; done
            check "shown again resumes the stream" ok "$(ipc status)"

            ipc stop >/dev/null
            check "stop(): status" stopped "$(ipc status)"
            check "stop(): content kept" true "$(ipc hasContent)"
            before="$(ipc frames)"; sleep 0.7
            check "stop(): no more frames" "$before" "$(ipc frames)"

            ipc clear >/dev/null
            check "captureSource null: status" idle "$(ipc status)"
            check "captureSource null: hasContent" false "$(ipc hasContent)"
        fi
        check "instance alive" alive "$(alive)"
        ;;
    *)
        printf '  FAIL  unexpected status %s (log %s)\n' "$status" "$LOG"; fails=$((fails+1))
        ipc dump
        ;;
esac

wait "$PERFPID" 2>/dev/null
spawned="$(/usr/bin/python3 -c 'import sys; t=open(sys.argv[1], errors="replace").read(); print("yes" if "screencapture" in t else "no")' "${TMPDIR:-/tmp}/qs-screencopy-children.txt")"
check "no screencapture child (qs-perf --children)" no "$spawned"

# The grant cannot be revoked for one process, so when this machine holds it
# the permission branch is walked a second time with the deny hook set.
if [ "$status" = ok ] && [ -z "${QS_SCREENCOPY_DENY:-}" ]; then
    kill "$PID" 2>/dev/null
    for _ in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
    echo "  -- rerun with QS_SCREENCOPY_DENY=1 to cover the permission path"
    QS_SCREENCOPY_DENY=1 bash "$0" || fails=$((fails+1))
fi

[ "$fails" -eq 0 ] && echo "screencopy: all checks passed ($status path)" || echo "screencopy: $fails check(s) failed ($status path)"
exit $(( fails > 0 ))
