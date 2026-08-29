#!/bin/bash
# The two in-process singletons behind ResourceUsage and the UPower shim:
# Quickshell.Cocoa.SystemStats and Quickshell.Cocoa.Power. Each probe runs as
# its own throwaway instance; values are checked against the system tools
# they replace (sysctl, pmset), the UPower shim is checked through its own
# probe, ResourceUsage is checked against a scratch view of the shell config,
# and qs-perf --children proves none of them spawn anything.
#
#   bash tests/native-stats-power.sh
#   QS_BINARY=<worktree>/Quickshell.app/Contents/MacOS/quickshell bash tests/native-stats-power.sh
#   QS_CONFIG_ROOT=<config checkout>/quickshell ...     the config to probe ResourceUsage in
#   PERF=40 ...                                          seconds of spawn watching (default 12)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${QS_BINARY:-$ROOT/bin/qs}"
PERF="${PERF:-12}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/quickshell-$UID}"
export QML2_IMPORT_PATH="$ROOT/shims${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
fail=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }
ipc() { "$BINARY" -p "$1" ipc call "${@:2}" 2>/dev/null | tr -d '\r'; }
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; [ -n "${SCRATCH:-}" ] && rm -rf "$SCRATCH"; }
trap cleanup EXIT

# Children seen under a pid over $PERF seconds; the count line is what matters.
spawns() {
    local out
    out="$("$ROOT/bin/qs-perf" --children "$1" "$PERF")"
    local n
    n="$(printf '%s\n' "$out" | sed -n 's/^children of [0-9]* over [0-9]*s: \([0-9]*\) seen.*/\1/p')"
    if [ "${n:-1}" = 0 ]; then ok "$2: 0 children over ${PERF}s"
    else bad "$2: $n children over ${PERF}s"; printf '%s\n' "$out" | sed -n '/by command line/,$p' | sed 's/^/        /'; fi
}

# --- SystemStats -----------------------------------------------------------
SYS="$ROOT/tests/_probe_sysstats.qml"
pid="$(QS_BINARY="$BINARY" "$ROOT/bin/qs-test" "$SYS" --shell)" || { bad "sysstats probe did not start"; exit 1; }
pids+=("$pid")
sleep 2.5   # > the probe's 1 s interval, so the timer has sampled
got="$(ipc "$SYS" sysstats check)"
[ "$got" = ok ] && ok "sysstats check == ok" || bad "sysstats check == $got"
got="$(ipc "$SYS" sysstats manual)"
[ "$got" = ok ] && ok "sysstats sample() emits sampled" || bad "sysstats manual == $got"
want="$(sysctl -n hw.memsize)"; got="$(ipc "$SYS" sysstats memTotal)"
[ "$got" = "$want" ] && ok "sysstats memTotal $got == hw.memsize" || bad "sysstats memTotal $got != hw.memsize $want"
spawns "$pid" "SystemStats"
kill "$pid" 2>/dev/null

# --- Power -----------------------------------------------------------------
POW="$ROOT/tests/_probe_power.qml"
pid="$(QS_BINARY="$BINARY" "$ROOT/bin/qs-test" "$POW" --shell)" || { bad "power probe did not start"; exit 1; }
pids+=("$pid")
got="$(ipc "$POW" power check)"
if [ "$got" = no-battery ]; then
    echo "  skip  power: no battery in this Mac"
else
    [ "$got" = ok ] && ok "power check == ok" || bad "power check == $got"
    batt="$(pmset -g batt)"
    want="$(printf '%s\n' "$batt" | sed -n 's/.*[[:space:]]\([0-9]*\)%.*/\1/p' | head -1)"
    got="$(ipc "$POW" power percentage)"
    if [ "$got" -ge $((want - 1)) ] 2>/dev/null && [ "$got" -le $((want + 1)) ]; then ok "power percentage $got == pmset $want (±1)"
    else bad "power percentage $got, pmset says $want"; fi
    want="$(printf '%s\n' "$batt" | sed -n 's/.*%; \([^;]*\);.*/\1/p' | head -1)"
    got="$(ipc "$POW" power state)"
    [ "$got" = "$want" ] && ok "power state '$got' == pmset" || bad "power state '$got', pmset says '$want'"
    want="$(pmset -g | sed -n 's/^ *lowpowermode *\([01]\).*/\1/p' | head -1)"
    got="$(ipc "$POW" power lowPowerMode)"
    [ "$got" = "$want" ] && ok "power lowPowerMode $got == pmset" || bad "power lowPowerMode $got, pmset says $want"
    spawns "$pid" "Power"
fi
kill "$pid" 2>/dev/null

# --- UPower shim on top of it ------------------------------------------------
UP="$ROOT/tests/_probe_upower.qml"
pid="$(QS_BINARY="$BINARY" "$ROOT/bin/qs-test" "$UP" --shell)" || { bad "upower probe did not start"; exit 1; }
pids+=("$pid")
got="$(ipc "$UP" upower check)"
[ "$got" = ok ] && ok "upower check == ok (no settle needed)" || bad "upower check == $got"
want="$(pmset -g batt | sed -n 's/.*[[:space:]]\([0-9]*\)%.*/\1/p' | head -1)"
got="$(ipc "$UP" upower percentage)"
[ "$got" = "$want" ] && ok "upower percentage $got == pmset" || bad "upower percentage $got, pmset says $want"
spawns "$pid" "UPower shim"
kill "$pid" 2>/dev/null

# --- ResourceUsage in the shell config ----------------------------------------
# Same scratch layout tests/sysstats.sh uses: symlinks to the config's entries
# plus the probe, so `qs.*` resolves and the live shell is never addressed.
CFG="${QS_CONFIG_ROOT:-$HOME/.config/quickshell}"
if [ -d "$CFG/services" ]; then
    SCRATCH="$(mktemp -d /tmp/qs-stats-power-test.XXXXXX)"
    ln -s "$CFG"/* "$SCRATCH/"; cp "$ROOT/tests/_probe_resourceusage.qml" "$SCRATCH/"
    RU="$SCRATCH/_probe_resourceusage.qml"
    pid="$(QS_BINARY="$BINARY" "$ROOT/bin/qs-test" "$RU" --shell)" || { bad "ResourceUsage probe did not load"; exit 1; }
    pids+=("$pid")
    sleep 1   # the one-off CPU-name sysctl at load is not what is being measured
    spawns "$pid" "ResourceUsage"
    got="$(ipc "$RU" probe check)"
    [ "$got" = ok ] && ok "ResourceUsage check == ok" || bad "ResourceUsage check == $got"
    kill "$pid" 2>/dev/null
else
    echo "  skip  ResourceUsage: no config at $CFG (QS_CONFIG_ROOT)"
fi
exit $fail
