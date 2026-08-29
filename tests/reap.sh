#!/bin/bash
# Acceptance test for bin/qs-reap, run against a private XDG_RUNTIME_DIR so it
# never touches the real one. Builds one dead instance dir, one instance dir
# whose lock is held (stands in for the live shell), one fresh unlocked dir
# (an instance still starting), and one orphan perl process whose command line
# is a mediaremote-adapter.pl; then checks the reaper removes exactly the dead
# dir and the orphan.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/qs-reap-test.XXXXXX)"
export XDG_RUNTIME_DIR="$T"
QS="$T/quickshell"
mkdir -p "$QS/by-id/dead1" "$QS/by-id/alive1" "$QS/by-id/fresh1" "$QS/by-pid" "$QS/by-shell/sid1" "$QS/by-path"
: > "$QS/by-id/dead1/instance.lock"; : > "$QS/by-id/alive1/instance.lock"; : > "$QS/by-id/fresh1/instance.lock"
touch -t 202001010000 "$QS/by-id/dead1" "$QS/by-id/alive1"
ln -s "$QS/by-id/dead1" "$QS/by-pid/999999"
ln -s "$QS/by-id/dead1" "$QS/by-shell/sid1/dead1"
ln -s "$QS/by-shell/sid1" "$QS/by-path/sid1"

# Hold a write lock on alive1's lock the way quickshell does (F_SETLK, fcntl).
/usr/bin/python3 -c '
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR); fcntl.lockf(fd, fcntl.LOCK_EX); time.sleep(60)' "$QS/by-id/alive1/instance.lock" >/dev/null 2>&1 </dev/null &
LOCKER=$!
# A perl whose argv names the adapter script, parented to this shell (not quickshell).
mkdir -p "$T/lib/media-control"; echo 'sleep 60;' > "$T/lib/media-control/mediaremote-adapter.pl"
/usr/bin/perl "$T/lib/media-control/mediaremote-adapter.pl" >/dev/null 2>&1 </dev/null &
ORPHAN=$!
sleep 0.5

fail=0
check() { if [ "$2" = "$3" ]; then printf '  PASS  %-34s %s\n' "$1" "$3"; else printf '  FAIL  %-34s got %s want %s\n' "$1" "$3" "$2"; fail=1; fi; }

out="$("$ROOT/bin/qs-reap")"
echo "  $out"
sleep 0.5
check "dead dir removed"          no  "$([ -d "$QS/by-id/dead1" ] && echo yes || echo no)"
check "locked dir kept"           yes "$([ -d "$QS/by-id/alive1" ] && echo yes || echo no)"
check "fresh dir kept"            yes "$([ -d "$QS/by-id/fresh1" ] && echo yes || echo no)"
check "dangling by-pid link gone" no  "$([ -L "$QS/by-pid/999999" ] && echo yes || echo no)"
check "empty by-shell dir gone"   no  "$([ -d "$QS/by-shell/sid1" ] && echo yes || echo no)"
check "orphan adapter killed"     no  "$(kill -0 "$ORPHAN" 2>/dev/null && echo yes || echo no)"
check "lock holder untouched"     yes "$(kill -0 "$LOCKER" 2>/dev/null && echo yes || echo no)"

kill "$LOCKER" "$ORPHAN" 2>/dev/null; wait "$LOCKER" "$ORPHAN" 2>/dev/null
rm -rf "$T"
exit $fail
