#!/bin/bash
# P0-09 acceptance: the notification wire protocol v2 end to end.
#
#   bash tests/notifications.sh            (QS_BINARY overrides bin/qs)
#
# Starts tests/_probe_notifications.qml as a throwaway instance, points
# notify-send at it with QS_SHELL_CONFIG, and asserts through the probe's IPC:
#   - -A/-i/-u/-c/-h reach Notification.actions/appIcon/urgency/hints
#   - invoking an action writes the identifier back to the waiting notify-send
#   - -r replaces in place (same id, no second notification signal)
#   - tracked = false closes with Dismissed; -w returns on close
#   - a notification the consumer never claims is dropped and reported closed
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export QS_BINARY="${QS_BINARY:-$ROOT/bin/qs}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/quickshell-$UID}"
PROBE="$ROOT/tests/_probe_notifications.qml"
export QS_SHELL_CONFIG="$PROBE"
export QML2_IMPORT_PATH="$ROOT/shims${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
NS="$ROOT/bin/notify-send"

PID="$("$ROOT/bin/qs-test" "$PROBE" --shell)" || { echo "FAIL: probe did not start"; exit 1; }
trap 'kill "$PID" 2>/dev/null' EXIT
fails=0
ipc() { "$QS_BINARY" -p "$PROBE" ipc call probe "$@" 2>/dev/null; }
check() { # name, python-expr over `r` (the ipc reply string)
    local name=$1 expr=$2 r=$3
    if python3 -c "import json,sys; r=sys.argv[1]; sys.exit(0 if ($expr) else 1)" "$r"; then
        printf '  PASS  %s\n' "$name"
    else
        printf '  FAIL  %s\n        got: %s\n' "$name" "$r"; fails=$((fails+1))
    fi
}
waitfor() { # file, seconds: wait until file is non-empty
    for _ in $(seq 1 $(( $2 * 10 ))); do [ -s "$1" ] && return 0; sleep 0.1; done; return 1
}

# 1. full-featured notification, notify-send waits for the action
OUT="$(mktemp)"
"$NS" -A 'act=Label' -A 'other=Other' -i com.apple.Safari -u critical -c im.received \
      -h int:x-count:3 -h string:desktop-entry:com.apple.Safari -h string:image-path:/tmp/img.png \
      -t 5000 T B >"$OUT" 2>/dev/null &
NSPID=$!
sleep 1.5
r="$(ipc last)"
check "actions=['act','other']" "json.loads(r)['actions']==['act','other']" "$r"
check "action texts" "json.loads(r)['actionTexts']==['Label','Other']" "$r"
check "appIcon=com.apple.Safari" "json.loads(r)['appIcon']=='com.apple.Safari'" "$r"
check "urgency=Critical" "json.loads(r)['urgency']==2 and json.loads(r)['urgencyName']=='Critical'" "$r"
check "hints.category + typed int hint" "json.loads(r)['hints']['category']=='im.received' and json.loads(r)['hints']['x-count']==3" "$r"
check "desktopEntry" "json.loads(r)['desktopEntry']=='com.apple.Safari'" "$r"
check "image=file:///tmp/img.png" "json.loads(r)['image']=='file:///tmp/img.png'" "$r"
check "expireTimeout=5000" "json.loads(r)['expireTimeout']==5000" "$r"
check "transient=false, tracked" "json.loads(r)['transient'] is False and json.loads(r)['tracked'] is True" "$r"
ID="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$r")"
ipc invoke "$ID" 0 >/dev/null
if waitfor "$OUT" 5; then check "invoke -> notify-send printed identifier" "r.strip()=='act'" "$(cat "$OUT")"
else printf '  FAIL  notify-send never received the action\n'; fails=$((fails+1)); kill $NSPID 2>/dev/null; fi
r="$(ipc events)"
check "invoke dismissed (not resident): closed $ID 2" "'closed $ID 2' in r" "$r"

# 2. replace in place
ID1="$("$NS" -p -a App1 First body)"
"$NS" -r "$ID1" -a App1 Second body2 -e >/dev/null
r="$(ipc get "$ID1")"
check "-r updates summary in place" "json.loads(r)['summary']=='Second' and json.loads(r)['transient'] is True" "$r"
r="$(ipc events)"
check "-r emitted one notification signal for id $ID1" "r.count('notification $ID1')==1" "$r"

# 3. tracked=false => Dismissed, and -w returns on close
OUT2="$(mktemp)"
( "$NS" -w -a WaitApp W body; echo "returned:$?" ) >"$OUT2" 2>/dev/null &
sleep 1.2
r="$(ipc last)"
ID2="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$r")"
ipc untrack "$ID2" >/dev/null
r="$(ipc events)"
check "tracked=false -> closed $ID2 2 (Dismissed)" "'closed $ID2 2' in r" "$r"
if waitfor "$OUT2" 5; then check "-w returned on close" "'returned:0' in r" "$(cat "$OUT2")"
else printf '  FAIL  notify-send -w did not return after close\n'; fails=$((fails+1)); fi
r="$(ipc count)"
check "closed notifications left the tracked set" "int(r)==1" "$r"

# 4. never-claimed notification: dropped, and -w does not hang
OUT3="$(mktemp)"
( "$NS" -w -a drop Dropped body; echo "returned:$?" ) >"$OUT3" 2>/dev/null &
if waitfor "$OUT3" 5; then check "unclaimed notification reported closed to -w" "'returned:0' in r" "$(cat "$OUT3")"
else printf '  FAIL  -w hung on an unclaimed notification\n'; fails=$((fails+1)); fi
r="$(ipc count)"
check "unclaimed notification not tracked" "int(r)==1" "$r"

# 5. legacy 7-arg call still works
r="$("$QS_BINARY" -p "$PROBE" ipc call notifications notify Legacy S B "" 0 -1 true 2>/dev/null)"
check "legacy notify() returns an id" "r.strip().isdigit()" "$r"
r="$(ipc last)"
check "legacy notify(): urgency Low, transient" "json.loads(r)['urgency']==0 and json.loads(r)['transient'] is True" "$r"

rm -f "$OUT" "$OUT2" "$OUT3"
[ "$fails" -eq 0 ] && echo "notifications: all checks passed" || echo "notifications: $fails check(s) failed"
exit $(( fails > 0 ))
