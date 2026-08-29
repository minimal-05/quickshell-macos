#!/bin/bash
# P0-07 acceptance: a copy made in another process reaches QML and the history.
#
#   bash tests/clipboard.sh                (QS_BINARY overrides bin/qs)
#
# Starts tests/_probe_clipboard.qml as a throwaway instance with a private
# history store (QS_CLIPHIST_DIR) and asserts:
#   - pbcopy from this shell fires Quickshell.clipboardTextChanged within 1.5 s
#     and clipboardText read in the handler is the new text
#   - bin/cliphist list/decode/delete/delete-query/wipe in cliphist's shape,
#     newest first, same content deduplicated, ids never reused
#   - bin/wl-copy / bin/wl-paste text and -t image/png round trips
#   - an image copy previews as `[[ binary data .. png WxH ]]`, which is what
#     end-4's Cliphist.entryIsImage matches
#   - a set from QML is recorded and signalled once
# The user's clipboard (its text, or its PNG when it holds no text) is put
# back at the end.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export QS_BINARY="${QS_BINARY:-$ROOT/bin/qs}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/quickshell-$UID}"
export QML2_IMPORT_PATH="$ROOT/shims${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
export PATH="$ROOT/bin:$PATH"
PROBE="$ROOT/tests/_probe_clipboard.qml"
TMP="$(mktemp -d /tmp/qs-clipboard.XXXXXX)"
export QS_CLIPHIST_DIR="$TMP/cliphist"

pbpaste >"$TMP/saved.txt"
SAVED_PNG=""
if [ ! -s "$TMP/saved.txt" ] && wl-paste -l 2>/dev/null | grep -q '^image/png$' && wl-paste -t image/png >"$TMP/saved.png" 2>/dev/null; then
    SAVED_PNG="$TMP/saved.png"
fi
PID=""
restore() {
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    if [ -n "$SAVED_PNG" ]; then wl-copy -t image/png <"$SAVED_PNG"; else pbcopy <"$TMP/saved.txt"; fi
    rm -rf "$TMP"
}
trap restore EXIT

PID="$("$ROOT/bin/qs-test" "$PROBE" --shell)" || { echo "FAIL: probe did not start"; exit 1; }
fails=0
ipc() { "$QS_BINARY" -p "$PROBE" ipc call clipboard "$@" 2>/dev/null | tr -d '\r'; }
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '        got:  %s\n        want: %s\n' "$2" "$3"; fi; }
changes_at_least() { for _ in $(seq 1 15); do [ "$(ipc changes)" -ge "$1" ] 2>/dev/null && return 0; sleep 0.1; done; return 1; }
top() { cliphist list | head -1; }
sha() { shasum | cut -d' ' -f1; }

T1="qs-clipboard-test-$RANDOM"
echo "$T1" | pbcopy
if changes_at_least 1; then ok "clipboardTextChanged within 1.5 s of pbcopy in another process"; else bad "clipboardTextChanged never fired for pbcopy"; fi
eq "clipboardText read in the handler is the new text" "$(ipc last)" "$T1"
eq "cliphist list: id<TAB>preview, newest first" "$(top | cut -f2)" "$T1"
ID1="$(top | cut -f1)"
eq "cliphist decode <id>" "$(cliphist decode "$ID1")" "$T1"
eq "cliphist decode from a list line on stdin" "$(top | cliphist decode)" "$T1"

echo "$T1" | pbcopy; changes_at_least 2
eq "same text again: one entry, same id" "$(cliphist list | grep -c "$T1")/$(top | cut -f1)" "1/$ID1"

T2="qs-clipboard-second-$RANDOM"
wl-copy -n "$T2"; changes_at_least 3
eq "wl-copy -n puts the words on the pasteboard, no newline" "$(pbpaste)" "$T2"
eq "wl-paste -n reads it back" "$(wl-paste -n)" "$T2"
eq "wl-paste appends the newline" "$(wl-paste | wc -l | tr -d ' ')" "1"
eq "newest entry first" "$(top | cut -f2)" "$T2"
eq "earlier entry moved down" "$(cliphist list | sed -n 2p | cut -f2)" "$T1"

printf 'line one\n\tline   two\n' | wl-copy; changes_at_least 4
eq "preview collapses whitespace to one line" "$(top | cut -f2)" "line one line two"
eq "decode keeps the original bytes" "$(cliphist decode "$(top | cut -f1)" | sha)" "$(printf 'line one\n\tline   two\n' | sha)"

/usr/bin/python3 - "$TMP/img.png" <<'PY'
import struct, sys, zlib
w, h = 3, 2
raw = b"".join(b"\x00" + bytes([255, 0, 0] * w) for _ in range(h))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY
wl-copy -t image/png <"$TMP/img.png"; changes_at_least 5
eq "image preview in cliphist's shape" "$(top | cut -f2 | sed -E 's/[0-9.]+ (B|KiB|MiB)/N/')" "[[ binary data N png 3x2 ]]"
if /usr/bin/python3 -c 'import re,sys; sys.exit(0 if re.match(r"^\d+\t\[\[.*binary data.*\d+x\d+.*\]\]$", sys.argv[1]) else 1)' "$(top)"; then ok "end-4 Cliphist.entryIsImage matches it"; else bad "end-4 Cliphist.entryIsImage does not match: $(top)"; fi
IDI="$(top | cut -f1)"
eq "decode is the PNG that was copied" "$(cliphist decode "$IDI" | sha)" "$(sha <"$TMP/img.png")"
eq "wl-paste -t image/png" "$(wl-paste -t image/png | sha)" "$(sha <"$TMP/img.png")"
eq "wl-paste -l lists image/png" "$(wl-paste -l | grep -c '^image/png$')" "1"

before="$(ipc changes)"
ipc set "from-qml-$T2" >/dev/null; sleep 0.6
eq "Quickshell.clipboardText = x is recorded" "$(top | cut -f2)" "from-qml-$T2"
eq "and signalled once, not again by the poll" "$(ipc changes)" "$((before + 1))"

top | cliphist delete
eq "cliphist delete (list line on stdin)" "$(cliphist list | grep -c "from-qml-$T2")" "0"
cliphist delete-query "$T1"
eq "cliphist delete-query" "$(cliphist list | grep -c "$T1")" "0"
n="$(cliphist list | wc -l | tr -d ' ')"
cliphist wipe
eq "cliphist wipe empties the list ($n entries before)" "$(cliphist list | wc -l | tr -d ' ')" "0"
eq "wipe removed the blobs" "$(ls "$QS_CLIPHIST_DIR/blobs" | wc -l | tr -d ' ')" "0"
echo "qs-clipboard-after-wipe-$RANDOM" | pbcopy; changes_at_least "$((before + 2))"
if [ "$(top | cut -f1)" -gt "$IDI" ] 2>/dev/null; then ok "ids keep counting after a wipe ($(top | cut -f1) > $IDI)"; else bad "id reused after wipe: $(top | cut -f1)"; fi

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
