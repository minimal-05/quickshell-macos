#!/bin/bash
# Acceptance test for the one-binary layout (src/launch/tools.cpp, qs-bundle):
#   - bin/ holds qs, .gitignore and symlinks onto qs, nothing else;
#   - `qs --tools` lists exactly what src/tools/ defines (every executable,
#     plus one tool per *.c), and every one of them has its bin/ symlink;
#   - every tool reaches the same file through bin/<name> and `qs <name>`
#     (QS_TOOL_DRY_RUN prints the exec instead of running tools that build,
#     restart the shell or open windows), and the side-effect-free ones print
#     the same --help through both;
#   - the bundle Mach-O started with argv[0] = hyprctl is hyprctl;
#   - the binary sets PATH, XDG_RUNTIME_DIR, QML2_IMPORT_PATH and the default
#     config name itself: an instance started with no environment at all
#     reports them, and `qs ipc` reaches it;
#   - qs-probe passes its hover table through bin/qs.
# Always this tree's own bundle. Starts only its own throwaway instances
# (tests/_probe_bundle.qml, the hover probe).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/Quickshell.app"
EXE="$APP/Contents/MacOS/quickshell"
TOOLS="$APP/Contents/Resources/tools"
QS="$ROOT/bin/qs"
PROBE="$ROOT/tests/_probe_bundle.qml"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

fail=0
check() { if [ "$2" = "$3" ]; then printf '  PASS  %-40s %s\n' "$1" "${3:0:60}"; else printf '  FAIL  %-40s got %s want %s\n' "$1" "$3" "$2"; fail=1; fi; }

[ -x "$EXE" ] || { echo "  FAIL  no $EXE (run bin/qs qs-build)"; exit 1; }

echo "bin/"
check "only qs, .gitignore and symlinks"  "" "$(find "$ROOT/bin" -mindepth 1 ! -name qs ! -name .gitignore ! -type l | sed "s|$ROOT/||" | tr '\n' ' ')"
check "every symlink points at qs"        "" "$(for l in "$ROOT/bin"/*; do [ -L "$l" ] && [ "$(readlink "$l")" != qs ] && basename "$l"; done | tr '\n' ' ')"
check "qs is a script, not a symlink"     no "$([ -L "$QS" ] && echo yes || echo no)"

echo "tools"
# What qs-bundle installs: every executable in src/tools, one tool per *.c.
expected_tools() {
    local f n
    for f in "$ROOT/src/tools"/*; do
        n="$(basename "$f")"
        case "$n" in
            *.c) echo "${n%.c}" ;;
            *)   [ -x "$f" ] && echo "$n" ;;
        esac
    done | sort
}
expected="$(expected_tools)"
listed="$("$QS" --tools)"
check "qs --tools == src/tools"           "$expected" "$listed"
check "same list through the Mach-O"      "$listed" "$("$EXE" --tools)"
check "every tool has bin/<tool> -> qs"   "" "$(for t in $listed; do [ -L "$ROOT/bin/$t" ] || echo "$t"; done | tr '\n' ' ')"
check "every symlink is a tool"           "" "$(for l in "$ROOT/bin"/*; do [ -L "$l" ] && [ ! -x "$TOOLS/$(basename "$l")" ] && basename "$l"; done | tr '\n' ' ')"
# warp.py is a tool since the Hyprland shim runs it by bare name
# (hl.dsp.cursor.move -> ["warp.py", x, y]): executable, with a shebang, so
# bin/warp.py -> qs -> tools/warp.py works without naming an interpreter.
check "warp.py is a tool with a shebang"   "tool" "$([ -x "$TOOLS/warp.py" ] && [ "$(head -c2 "$TOOLS/warp.py")" = "#!" ] && echo tool)"

echo "dispatch"
wrong=""
for t in $listed; do
    want="exec $TOOLS/$t $t --help"
    via_link="$(QS_TOOL_DRY_RUN=1 "$ROOT/bin/$t" --help 2>&1)"
    via_sub="$(QS_TOOL_DRY_RUN=1 "$QS" "$t" --help 2>&1)"
    [ "$via_link" = "$want" ] && [ "$via_sub" = "$want" ] || wrong="$wrong $t"
done
check "bin/<t> and qs <t> exec the same file ($(echo "$listed" | wc -l | tr -d ' ') tools)" "" "$wrong"
# Real --help, where it is safe: these print usage and exit. The others build,
# restart the shell, open windows or start daemons on any argument.
wrong=""
for t in hyprctl hyprsunset loginctl systemctl reboot ydotool secret-tool checkupdates qs-test qs-reap qs-perf qs-ipc; do
    a="$("$ROOT/bin/$t" --help 2>&1)"; b="$("$QS" "$t" --help 2>&1)"
    [ -n "$a" ] && [ "$a" = "$b" ] || wrong="$wrong $t"
done
check "--help identical through both routes" "" "$wrong"
check "builtin subcommands are not tools"  "" "$(for b in log list kill ipc msg; do [ -e "$TOOLS/$b" ] && echo "$b"; done | tr '\n' ' ')"
check "qs --version is quickshell's"       "Quickshell" "$("$QS" --version | awk '{print $1}')"
pos="$( (exec -a hyprctl "$EXE" cursorpos) 2>&1)"
check "Mach-O with argv[0]=hyprctl is hyprctl" ok "$(/usr/bin/python3 -c 'import re,sys; print("ok" if re.fullmatch(r"-?\d+, -?\d+", sys.argv[1]) else sys.argv[1])' "$pos")"

echo "environment"
# The instance itself, from nothing: no PATH worth having, no runtime dir, no
# import path, no config name. Everything it reports below came from the binary.
if pgrep -f -- "-p $PROBE" >/dev/null 2>&1; then echo "  FAIL  an instance on $PROBE is already running"; exit 1; fi
LOG="${TMPDIR:-/tmp}/qs-one-binary.log"; : > "$LOG"
env -i HOME="$HOME" PATH=/usr/bin:/bin nohup "$QS" -p "$PROBE" > "$LOG" 2>&1 &
pid=$!; disown
trap 'kill "$pid" 2>/dev/null' EXIT
for _ in $(seq 1 80); do /usr/bin/python3 -c 'import sys; sys.exit(0 if "Configuration Loaded" in open(sys.argv[1], errors="replace").read() else 1)' "$LOG" && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
check "instance loaded from an empty env" yes "$(kill -0 "$pid" 2>/dev/null && echo yes || { tail -3 "$LOG"; echo no; })"
check "instance runs the bundle Mach-O"    "$EXE" "$(ps -o comm= -p "$pid" 2>/dev/null)"
envs="$(XDG_RUNTIME_DIR= "$QS" -p "$PROBE" ipc call probe env 2>/dev/null | tr -d '\r')"
val() { printf '%s\n' "$envs" | sed -n "s/^$1=//p"; }
case "$(val PATH)" in "$TOOLS:$ROOT/bin:/opt/homebrew/bin:/usr/local/bin:"*) path_ok=yes ;; *) path_ok="$(val PATH)" ;; esac
check "PATH starts with tools, then bin/"  yes "$path_ok"
check "XDG_RUNTIME_DIR defaulted"          "/tmp/quickshell-$(id -u)" "$(val XDG_RUNTIME_DIR)"
check "QML2_IMPORT_PATH has shims/"        "$ROOT/shims" "$(val QML2_IMPORT_PATH | tr ':' '\n' | head -1)"
check "QS_CONFIG_NAME unset under -p"      "" "$(val QS_CONFIG_NAME)"
check "qs ipc reaches it"                  "$pid" "$("$QS" -p "$PROBE" ipc call probe pid 2>/dev/null | tr -d '\r\n')"
# BSD pgrep skips its own ancestors, so the process asked about is the
# instance, not this script's bash.
check "Mach-O with argv[0]=pidof is pidof" "$pid" "$( (exec -a pidof "$EXE" quickshell) 2>/dev/null | tr ' ' '\n' | awk -v me="$pid" '$1 == me')"
check "qs-ipc tool reaches it (QS_CONFIG_PATH)" "$pid" "$(QS_CONFIG_PATH="$PROBE" "$ROOT/bin/qs-ipc" probe pid 2>/dev/null | tr -d '\r\n')"
kill "$pid" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.3; done
kill -9 "$pid" 2>/dev/null

echo "qs-probe"
out="$("$ROOT/bin/qs-probe" 2>&1)"
check "hover probe through bin/qs-probe"   "5 passed, 0 failed" "$(printf '%s\n' "$out" | sed -n 's/^  \([0-9]* passed, [0-9]* failed\)$/\1/p')"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
