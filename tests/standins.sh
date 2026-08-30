#!/bin/bash
# Exercise every verb of the Linux-tool stand-ins in bin/ without doing
# anything destructive: session verbs only through --dry-run, key events only
# through --dry-run, gamma on a private daemon socket, Night Shift put back
# on exit, the keychain item deleted again, the focused Space restored.
#
#   bash tests/standins.sh          (STANDINS_NO_SPACE=1 skips the Space switch)
#
# The Space switch is the plan's acceptance test for `hyprctl dispatch`; it is
# the one visible step and it can be upset by a person switching Spaces while
# it runs -- rerun if only that line fails.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
B="$ROOT/bin"
export PATH="$B:/opt/homebrew/bin:/usr/local/bin:$PATH"
export XDG_RUNTIME_DIR="$(mktemp -d /tmp/standins.XXXXXX)"
export HYPRSUNSET_SOCK="$XDG_RUNTIME_DIR/hyprsunset.sock" HYPRSUNSET_LOG="$XDG_RUNTIME_DIR/hyprsunset.log"
fail=0
ok()   { printf '  PASS  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
eq()   { local name="$1" got="$2" want="$3"; [ "$got" = "$want" ] && ok "$name ($got)" || bad "$name: got '$got' want '$want'"; }
# Night Shift is the user's live setting: --identity and `temperature 6000`
# both switch it off, so its on/off and preference are taken here and put
# back in the trap, whichever line fails.
if command -v nightlight >/dev/null 2>&1; then
    ns_on=0; nightlight status 2>/dev/null | grep -q '^on' && ns_on=1
    ns_pct="$(nightlight temp 2>/dev/null)"
fi
cleanup() {
    "$B/hyprsunset" --quit >/dev/null 2>&1
    if [ -n "${ns_pct:-}" ]; then
        nightlight temp "$ns_pct" >/dev/null 2>&1
        if [ "$ns_on" = 1 ]; then nightlight on >/dev/null 2>&1; else nightlight off >/dev/null 2>&1; fi
    fi
    rm -rf "$XDG_RUNTIME_DIR"
}
trap cleanup EXIT

echo "hyprctl"
for t in hyprctl hyprsunset loginctl systemctl reboot ydotool secret-tool checkupdates; do
    check "$t --help" "$B/$t" --help
done
pos="$("$B/hyprctl" cursorpos)"
check "cursorpos 'x, y'" python3 -c "import re,sys; sys.exit(0 if re.fullmatch(r'-?\d+, -?\d+', sys.argv[1]) else 1)" "$pos"
# Not compared with the plain form: the pointer may move between the two calls.
eq "cursorpos -j shape" "$("$B/hyprctl" -j cursorpos | jq -c 'map_values(type)')" '{"x":"number","y":"number"}'
n="$("$B/hyprctl" -j binds | jq length)"; [ "${n:-0}" -gt 0 ] && ok "binds -j length $n" || bad "binds -j empty"
eq "binds have Category: descriptions" "$("$B/hyprctl" binds -j | jq '[.[] | select(.description | contains(":"))] | length > 0')" "true"
printf '{"quickshell:lock":"ctrl+alt+cmd+l"}' >"$XDG_RUNTIME_DIR/shortcuts.json"
eq "binds from shortcuts.json" "$(QS_SHORTCUTS="$XDG_RUNTIME_DIR/shortcuts.json" "$B/hyprctl" -j binds | jq -c '.[0] | [.modmask,.key,.dispatcher,.arg]')" '[76,"L","global","quickshell:lock"]'
eq "monitors -j has focused display" "$("$B/hyprctl" monitors -j | jq '[.[] | select(.focused)] | length >= 1')" "true"
eq "monitors -j activeWorkspace" "$("$B/hyprctl" monitors -j | jq '.[0].activeWorkspace.id >= 1')" "true"
eq "-j devices main keyboard" "$("$B/hyprctl" -j devices | jq '.keyboards[] | select(.main) | .layout | length > 0')" "true"
eq "getoption -j .set" "$("$B/hyprctl" getoption -j general:gaps_in | jq .set)" "false"
eq "getoption animations:enabled -j .int" "$("$B/hyprctl" getoption animations:enabled -j | jq .int)" "1"
check "keyword no-op" "$B/hyprctl" keyword general:gaps_in 0
check "reload no-op" "$B/hyprctl" reload
check "--batch" "$B/hyprctl" --batch "keyword animations:enabled 0; keyword decoration:blur:enabled 0"
eq "dispatch focus workspace (dry)" "$("$B/hyprctl" --dry-run dispatch 'hl.dsp.focus({workspace=3})')" "yabai -m space --focus 3"
eq "dispatch focus monitor (dry)" "$("$B/hyprctl" --dry-run dispatch 'hl.dsp.focus({monitor="Display-1"})')" "yabai -m display --focus 1"
eq "dispatch lock temp workspace is a no-op" "$("$B/hyprctl" --dry-run dispatch 'hl.dsp.focus({workspace=2147483646})' 2>/dev/null)" "ok"
check "dispatch cursor.move (dry) -> warp.py" bash -c "'$B/hyprctl' --dry-run dispatch 'hl.dsp.cursor.move({x=10,y=20})' | grep -q 'warp.py 10 20'"
check "unknown subcommand exits 1" bash -c "! '$B/hyprctl' bogus 2>/dev/null"
if [ -z "${STANDINS_NO_SPACE:-}" ] && yabai -m query --spaces >/dev/null 2>&1; then
    before="$(yabai -m query --spaces --space | jq .index)"
    target=2; [ "$before" = "2" ] && target=1
    if [ "$(yabai -m query --spaces | jq length)" -ge "$target" ]; then
        # Mission Control animates the switch; poll instead of guessing a delay.
        space_is() { for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(yabai -m query --spaces --space | jq .index)" = "$1" ] && return 0; sleep 0.3; done; return 1; }
        # Switching Spaces is the one yabai call that needs its scripting
        # addition (sudo yabai --load-sa); without it yabai says so and the
        # stand-in relays it, which is a skip here, not a stand-in fault.
        out="$("$B/hyprctl" dispatch "workspace $target" 2>&1)"
        case "$out" in
            *scripting-addition*) echo "  SKIP  Space switch: yabai scripting addition not loaded" ;;
            *)
                check "dispatch 'workspace $target' focused Space $target" space_is "$target"
                "$B/hyprctl" dispatch "hl.dsp.focus({workspace=$before})" >/dev/null
                check "Space restored to $before" space_is "$before" ;;
        esac
    fi
fi

echo "hyprsunset"
check "--identity" "$B/hyprsunset" --identity
eq "hyprctl hyprsunset gamma 80" "$("$B/hyprctl" hyprsunset gamma 80)" "ok"
check "daemon log line" grep -q "gamma 80" "$HYPRSUNSET_LOG"
check "pidof hyprsunset" "$B/pidof" hyprsunset
eq "gamma readback" "$("$B/hyprsunset" --gamma)" "80"
eq "gamma clamps to 25" "$("$B/hyprctl" hyprsunset gamma 5 >/dev/null; "$B/hyprsunset" --gamma)" "25"
"$B/hyprctl" hyprsunset gamma 100 >/dev/null
if [ -n "${ns_pct:-}" ]; then
    "$B/hyprctl" hyprsunset temperature 4000 >/dev/null
    eq "temperature 4000 -> Night Shift on" "$(nightlight status | grep -c '^on')" "1"
    eq "temperature readback" "$("$B/hyprctl" hyprsunset temperature)" "4000"
    "$B/hyprctl" hyprsunset temperature 6000 >/dev/null
    eq "temperature 6000 -> off reads 6000" "$("$B/hyprctl" hyprsunset temperature)" "6000"
else
    echo "  SKIP  nightlight not installed (brew install nightlight)"
fi
check "--quit" "$B/hyprsunset" --quit

echo "loginctl / systemctl / reboot (dry-run only)"
check "lock-session" bash -c "'$B/loginctl' --dry-run lock-session | grep -q 'pmset displaysleepnow'"
check "lock-session QS_LOCK=screensaver" bash -c "QS_LOCK=screensaver '$B/loginctl' --dry-run lock-session | grep -q ScreenSaverEngine"
check "suspend" bash -c "'$B/loginctl' --dry-run suspend | grep -q 'pmset sleepnow'"
check "systemctl poweroff" bash -c "'$B/systemctl' --dry-run poweroff | grep -q 'shut down'"
check "systemctl reboot" bash -c "'$B/systemctl' --dry-run reboot | grep -q restart"
check "reboot" bash -c "'$B/reboot' --dry-run | grep -q restart"
check "terminate-session" bash -c "'$B/loginctl' --dry-run terminate-session | grep -q 'log out'"
check "hibernate exits 1" bash -c "! '$B/systemctl' hibernate 2>/dev/null"
check "hibernate says not supported" bash -c "'$B/loginctl' hibernate 2>&1 | grep -q 'not supported on macOS'"
check "--firmware-setup exits 1" bash -c "! '$B/systemctl' reboot --firmware-setup 2>/dev/null"

echo "ydotool (dry-run only)"
paste="$("$B/ydotool" --dry-run key -d 1 29:1 47:1 47:0 29:0)"
eq "paste chord is cmd+v" "$(printf '%s\n' "$paste" | sed -n 2p)" "down vk=9 flags=0x100000"
eq "modifier released" "$(printf '%s\n' "$paste" | sed -n 4p)" "up vk=55 flags=0x0"
"$B/ydotool" --dry-run key --key-delay 0 42:1 >/dev/null
eq "shift held across calls" "$("$B/ydotool" --dry-run key --key-delay 0 30:1 | head -1)" "down vk=0 flags=0x20000"
"$B/ydotool" --dry-run key --key-delay 0 42:0 54:0 >/dev/null
eq "shift released across calls" "$("$B/ydotool" --dry-run key --key-delay 0 30:1 | head -1)" "down vk=0 flags=0x0"
eq "type" "$("$B/ydotool" --dry-run type hi | wc -l | tr -d ' ')" "4"
check "unknown verb exits 1" bash -c "! '$B/ydotool' mousemove 2>/dev/null"

echo "secret-tool"
echo '{"probe":1}' | "$B/secret-tool" store --label=qs-standins-test application qs-standins-test
eq "store/lookup" "$("$B/secret-tool" lookup application qs-standins-test)" '{"probe":1}'
"$B/secret-tool" clear application qs-standins-test
eq "clear" "$("$B/secret-tool" lookup application qs-standins-test)" ""

echo "checkupdates"
"$B/checkupdates" >"$XDG_RUNTIME_DIR/cu" 2>/dev/null; rc=$?
[ "$rc" = 0 ] || [ "$rc" = 2 ] && ok "checkupdates exit $rc, $(wc -l <"$XDG_RUNTIME_DIR/cu" | tr -d ' ') lines" || bad "checkupdates exit $rc"
[ "$rc" != 0 ] || check "lines are 'name old -> new'" bash -c "! grep -vqE '^[^ ]+ [^ ]+ -> [^ ]+$' '$XDG_RUNTIME_DIR/cu'"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
