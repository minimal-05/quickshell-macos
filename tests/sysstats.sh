#!/bin/bash
# qs-sysstats: the helper emits the fields ResourceUsage.qml needs, CPU ticks
# are cumulative (monotonic across runs), and the python fallback agrees with
# the compiled binary. Then the service itself: _probe_resourceusage.qml runs
# against a scratch view of the shell config (QS_CONFIG_ROOT, default
# ~/.config/quickshell -- never written to) in a throwaway instance, and must
# turn two samples into a real CPU% without spawning `top`.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/qs-sysstats.bin"
PY="$ROOT/src/tools/qs-sysstats.py"
fail=0
ok()   { printf '  PASS  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }

[ -x "$BIN" ] || cc -O2 -Wall -o "$BIN" "$ROOT/src/tools/qs-sysstats.c" || { bad "compile"; exit 1; }

a="$("$BIN")"; sleep 0.3; b="$("$BIN")"; c="$(/usr/bin/python3 "$PY")"; d="$("$ROOT/bin/qs-sysstats")"
/usr/bin/python3 - "$a" "$b" "$c" "$d" <<'PY' || fail=1
import json, sys
a, b, c, d = (json.loads(x) for x in sys.argv[1:5])
def ok(m): print(f"  PASS  {m}")
def bad(m): print(f"  FAIL  {m}"); sys.exit(1)
for name, s in (("binary", a), ("python fallback", c), ("bin/qs-sysstats", d)):
    for k in ("cpu", "mem", "swap", "load"):
        k in s or bad(f"{name}: missing {k}")
    for k in ("user", "system", "idle", "nice"):
        k in s["cpu"] or bad(f"{name}: missing cpu.{k}")
    for k in ("total", "used", "available", "pagesize"):
        k in s["mem"] or bad(f"{name}: missing mem.{k}")
    for k in ("total", "used", "free"):
        k in s["swap"] or bad(f"{name}: missing swap.{k}")
    len(s["load"]) == 3 or bad(f"{name}: load has {len(s['load'])} entries")
ok("all fields present in binary, fallback and dispatcher")
tot = lambda s: sum(s["cpu"].values())
tot(b) > tot(a) and b["cpu"]["idle"] >= a["cpu"]["idle"] or bad("cpu ticks not cumulative")
ok(f"cpu ticks cumulative: total {tot(a)} -> {tot(b)}")
a["mem"]["total"] == c["mem"]["total"] and a["mem"]["pagesize"] == c["mem"]["pagesize"] or bad("fallback memsize/pagesize differ")
abs(a["mem"]["used"] - c["mem"]["used"]) < 512 * 2**20 or bad(f"fallback used differs: {a['mem']['used']} vs {c['mem']['used']}")
a["swap"]["total"] == c["swap"]["total"] or bad("fallback swap differs")
ok("python fallback agrees with the binary")
0 < a["mem"]["used"] < a["mem"]["total"] and a["mem"]["used"] + a["mem"]["available"] == a["mem"]["total"] or bad("mem used/available inconsistent")
ok("mem used + available == total")
PY

# Service-level check. The scratch dir is symlinks to the config's top-level
# entries plus the probe: `qs.*` imports resolve from the root file's directory,
# and the instance id from its path, so nothing here can reach the live shell.
CFG="${QS_CONFIG_ROOT:-$HOME/.config/quickshell}"
QS="${QS_BINARY:-$ROOT/bin/quickshell}"
if [ -d "$CFG/services" ] && [ -x "$QS" ]; then
    T="$(mktemp -d /tmp/qs-sysstats-test.XXXXXX)"
    ln -s "$CFG"/* "$T/"; cp "$ROOT/tests/_probe_resourceusage.qml" "$T/"
    PROBE="$T/_probe_resourceusage.qml"
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/quickshell-$UID}"   # same instance dir qs-test uses
    pid="$(QS_BINARY="$QS" "$ROOT/bin/qs-test" "$PROBE" --shell)" || { bad "probe did not load"; rm -rf "$T"; exit 1; }
    trap 'kill "$pid" 2>/dev/null; rm -rf "$T"' EXIT
    # Watch the window in which two samples land (default updateInterval 3000 ms)
    # with qs-perf: reaped-child CPU is the kernel's own count of what the
    # service spawned, so a `top` that lives 100 ms cannot slip between samples.
    perf="$("$ROOT/bin/qs-perf" "$pid" 7)"
    out="$("$QS" -p "$PROBE" ipc call probe check 2>&1 | tr -d '\r')"
    [ "$out" = "ok" ] && ok "ResourceUsage probe: $out" || bad "ResourceUsage probe: $out"
    pct="$(printf '%s\n' "$perf" | awk '/reaped-children CPU %/ {print $4}')"
    if /usr/bin/python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 1.0 else 1)' "$pct" \
       && ! printf '%s\n' "$perf" | awk '/top children/' | /usr/bin/python3 -c 'import sys; sys.exit(1 if " top" in sys.stdin.read() else 0)'; then
        bad "service still spawns top (reaped-child CPU ${pct}%)"; printf '%s\n' "$perf" | awk '/top children/'
    elif /usr/bin/python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 1.0 else 1)' "$pct"; then
        ok "reaped-child CPU ${pct}% over 7 s, no top child"
    else
        bad "reaped-child CPU ${pct}% over 7 s (top -l 1 costs ~5%; the helper ~0.2%)"
    fi
else
    echo "  skip  service probe: need a config at $CFG and a binary at $QS (QS_CONFIG_ROOT / QS_BINARY)"
fi
exit $fail
