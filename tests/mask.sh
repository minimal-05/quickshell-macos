#!/bin/bash
# P1-01: PanelWindow.mask is a hit-test region, and rendering is unclipped.
#
#   bash tests/mask.sh            (QS_BINARY overrides the binary, as in qs-test)
#
# A full-width panel with a 200x100 mask: the pointer moved into the mask
# hovers the panel, moved onto the panel outside the mask does not. The native
# window's bounds and alpha, read from the window server, stay the full panel
# throughout. Then the mask is emptied (never hovers) and dropped (whole panel
# hovers) and the same checks repeat.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/quickshell-$UID}"
export QML2_IMPORT_PATH="$ROOT/shims${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
# A throwaway instance must not push its panel's zone into yabai.
export QS_NO_YABAI_ZONES=1

BINARY="${QS_BINARY:-$ROOT/bin/qs}"
QML="$ROOT/tests/mask.qml"
LOG=/tmp/qs-test-mask.log
WARP="$ROOT/bin/warp.py"

PID="$("$ROOT/bin/qs-test" "$QML" --binary "$BINARY" --log "$LOG" --shell)" \
    || { echo "probe failed to start; see $LOG" >&2; exit 1; }
stop() { kill "$PID" 2>/dev/null; }
trap stop EXIT

ask() { "$BINARY" -p "$QML" ipc call probe "$@" 2>/dev/null | tr -d '\r\n'; }
move() { /usr/bin/python3 "$WARP" "$1" "$2" >/dev/null 2>&1; sleep 0.4; }

# The panel's on-screen windows as the window server sees them: "x,y,w,h,alpha"
# per window owned by the probe, largest first.
native_windows() {
    # JXA does not bridge CGWindowListCopyWindowInfo on its own; bind it.
    # 1 = kCGWindowListOptionOnScreenOnly, 0 = kCGNullWindowID.
    osascript -l JavaScript -e '
        ObjC.import("CoreGraphics");
        ObjC.bindFunction("CGWindowListCopyWindowInfo", ["id", ["unsigned int", "unsigned int"]]);
        const pid = '"$PID"';
        const list = ObjC.deepUnwrap($.CGWindowListCopyWindowInfo(1, 0)) || [];
        const mine = list.filter(w => w.kCGWindowOwnerPID === pid).map(w => {
            const b = w.kCGWindowBounds;
            return {x: b.X, y: b.Y, w: b.Width, h: b.Height, a: w.kCGWindowAlpha};
        }).sort((p, q) => q.w * q.h - p.w * p.h);
        mine.map(w => `${w.x},${w.y},${w.w},${w.h},${w.a}`).join("\n");
    ' 2>/dev/null
}

pass=0; fail=0
check() {  # label expected actual
    if [ "$2" = "$3" ]; then printf '  PASS  %-44s %s\n' "$1" "$3"; pass=$((pass+1))
    else printf '  FAIL  %-44s got %-9s want %s\n' "$1" "$3" "$2"; fail=$((fail+1)); fi
}

sleep 0.5
geom="$(ask geometry)"; mask="$(ask maskRect)"
IFS=, read -r gx gy gw gh <<<"$geom"
IFS=, read -r mx my mw mh <<<"$mask"
echo "  panel $geom  mask $mask"
in_x=$(( mx + mw / 2 )); in_y=$(( my + mh / 2 ))          # centre of the mask
out_x=$(( gx + gw - 60 )); out_y=$(( gy + gh - 30 ))        # on the panel, far from the mask
off_x=$(( gx + gw / 2 )); off_y=$(( gy + gh + 300 ))        # below the panel

# Unclipped: the window server sees the whole panel, not the mask.
native="$(native_windows | head -1)"
check "native window is the full panel (x,y,w,h,alpha)" "$geom,1" "$native"

move "$off_x" "$off_y"; check "small mask: pointer off the panel" outside "$(ask hover)"
move "$in_x" "$in_y";   check "small mask: pointer inside the mask" inside "$(ask hover)"
move "$out_x" "$out_y"; check "small mask: on the panel, outside the mask" outside "$(ask hover)"
move "$in_x" "$in_y";   check "small mask: back inside" inside "$(ask hover)"
check "native window unchanged while masked" "$geom,1" "$(native_windows | head -1)"

ask setMask empty >/dev/null; sleep 0.3
check "empty mask: pointer still in the rect, no hover" outside "$(ask hover)"
move "$out_x" "$out_y"; move "$in_x" "$in_y"
check "empty mask: never hovers" outside "$(ask hover)"

ask setMask full >/dev/null; sleep 0.3
check "no mask: pointer in the rect hovers" inside "$(ask hover)"
move "$out_x" "$out_y"; check "no mask: anywhere on the panel hovers" inside "$(ask hover)"
move "$off_x" "$off_y"; check "no mask: off the panel" outside "$(ask hover)"

ask setMask small >/dev/null; sleep 0.3
move "$out_x" "$out_y"; check "small mask again: outside the mask" outside "$(ask hover)"
move "$in_x" "$in_y";   check "small mask again: inside" inside "$(ask hover)"
check "native window still the full panel" "$geom,1" "$(native_windows | head -1)"

/usr/bin/python3 - "$LOG" <<'PY'
import sys
for line in open(sys.argv[1], errors='replace'):
    if 'cocoa: mask' in line: print('  log:', line.rstrip()[-60:])
PY
echo "  events: $(ask events)"
echo "  $pass passed, $fail failed"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
