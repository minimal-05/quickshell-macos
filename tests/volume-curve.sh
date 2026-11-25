#!/bin/bash
# The volume step curve, checked without touching the user's audio.
#
#   tests/volume-curve.sh
#
# qs-volume's fallback path is driven with a stub `osascript` on PATH holding
# the volume in a file, and the script copied somewhere its sibling `qs-ipc` is
# absent so the shell branch always misses. What is asserted is the property the
# curve exists for: the macOS volume scalar is linear in dB (measured through
# kAudioDevicePropertyVolumeScalarToDecibels on the built-in output: scalar 0 ->
# -63.5 dB, scalar 1 -> 0 dB), so equal steps are what make every press an equal
# loudness change. A curve other than 1.0 bends that back out of true -- at the
# old 1.5 the first press off zero moved 0.99 dB and one at the top moved 5.86.
#
# Also asserts the two copies of the formula agree: services/Audio.qml owns it
# for the running shell, qs-volume repeats it for when the shell is down.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_AT_ZERO=-63.5   # measured; full scale is 0 dB
STEP_DB=3.96875    # 63.5 / 16
TOL=0.8            # whole-percent rounding is worth about +-0.32 dB

fail=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp "$ROOT/src/tools/qs-volume" "$tmp/qs-volume"   # no qs-ipc beside it: fallback only

mkdir -p "$tmp/bin"
cat > "$tmp/bin/osascript" <<'STUB'
#!/bin/bash
# Just enough of osascript for qs-volume: volume and mute in two files.
state="$TMPDIR_VOL/vol"; mute="$TMPDIR_VOL/mute"
case "$2" in
    "output volume of (get volume settings)") cat "$state" ;;
    "set volume output muted true")  echo true  > "$mute" ;;
    "set volume output muted false") echo false > "$mute" ;;
    "set volume output volume "*)    echo "${2##* }" > "$state" ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/osascript"
export TMPDIR_VOL="$tmp"
export PATH="$tmp/bin:$PATH"

vol()   { cat "$tmp/vol"; }
muted() { cat "$tmp/mute"; }
press() { "$tmp/qs-volume" "$1" >/dev/null 2>&1; }

# 16 presses up from silence must land exactly on 100.
echo 0 > "$tmp/vol"; echo true > "$tmp/mute"
table=(0)
for _ in $(seq 16); do press up; table+=("$(vol)"); done
[ "$(vol)" = 100 ] && ok "16 presses up from 0 reach 100" \
                   || bad "16 presses up from 0 reach 100 (got $(vol), table: ${table[*]})"

# Every press must be the same loudness change.
VOLS="${table[*]}" DB0="$DB_AT_ZERO" STEP="$STEP_DB" TOL="$TOL" python3 - <<'PY'
import os, sys
vols = [int(v) for v in os.environ["VOLS"].split()]
db0, step, tol = float(os.environ["DB0"]), float(os.environ["STEP"]), float(os.environ["TOL"])
db = [db0 * (1 - v / 100.0) for v in vols]          # linear scalar -> dB
deltas = [b - a for a, b in zip(db, db[1:])]
worst = max(abs(d - step) for d in deltas)
if worst <= tol:
    print(f"  PASS  every press is {step:.2f} dB +-{tol} (worst off by {worst:.2f})")
else:
    print(f"  FAIL  uneven steps, worst off by {worst:.2f} dB")
    print("        " + " ".join(f"{d:.2f}" for d in deltas))
    sys.exit(1)
PY
[ $? -ne 0 ] && fail=1

# The bottom step has to be real silence: scalar 0 is about -63 dB, not quiet.
echo 6 > "$tmp/vol"; echo false > "$tmp/mute"
press down
[ "$(vol)" = 0 ] && [ "$(muted)" = true ] \
    && ok "stepping down off the last notch hits 0 and mutes" \
    || bad "stepping down off the last notch hits 0 and mutes (vol=$(vol) muted=$(muted))"

press up
[ "$(muted)" = false ] && [ "$(vol)" != 0 ] \
    && ok "stepping up off 0 unmutes" \
    || bad "stepping up off 0 unmutes (vol=$(vol) muted=$(muted))"

# One formula, two copies.
qml="$HOME/.config/quickshell/end4/services/Audio.qml"
if [ -r "$qml" ]; then
    sh_curve=$(sed -n 's/^CURVE=\([0-9.]*\).*/\1/p' "$ROOT/src/tools/qs-volume")
    sh_steps=$(sed -n 's/^STEPS=\([0-9]*\).*/\1/p' "$ROOT/src/tools/qs-volume")
    qml_curve=$(sed -n 's/.*property real curve: \([0-9.]*\).*/\1/p' "$qml")
    qml_steps=$(sed -n 's/.*property int volumeSteps: \([0-9]*\).*/\1/p' "$qml")
    [ "$sh_curve" = "$qml_curve" ] && [ "$sh_steps" = "$qml_steps" ] \
        && ok "qs-volume and Audio.qml agree (curve $sh_curve, $sh_steps steps)" \
        || bad "qs-volume has curve $sh_curve/$sh_steps steps, Audio.qml has $qml_curve/$qml_steps"
else
    echo "  SKIP  Audio.qml not readable at $qml"
fi

exit $fail
