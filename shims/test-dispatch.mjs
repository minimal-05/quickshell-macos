// Runnable check for the shim's window.move translation.
//
//   node shims/test-dispatch.mjs
//
// Hyprland.qml is QML, but translateLuaDispatch() is plain JS with no QML
// dependencies beyond root.resolveWorkspaceIndex, so the real function is
// lifted out of the shipped file and run against a stub. Testing a copy of the
// logic would guard nothing.

import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const src = readFileSync(new URL("./Quickshell/Hyprland/Hyprland.qml", import.meta.url), "utf8");

const start = src.indexOf("function translateLuaDispatch(cmd: string): var {");
assert.notEqual(start, -1, "translateLuaDispatch not found — did the shim move?");
// Brace counting would trip over the `}` inside the character class in field()'s
// regex, so cut at the banner comment that follows the function instead.
const banner = src.indexOf("\n    // ---", start);
assert.notEqual(banner, -1, "no banner comment after translateLuaDispatch");
const end = src.lastIndexOf("}", banner) + 1;

const body = src.slice(start, end).replace("function translateLuaDispatch(cmd: string): var {", "function translateLuaDispatch(cmd) {");

const root = {
    // Spaces 1..10, so a numeric workspace resolves to itself.
    resolveWorkspaceIndex: a => (/^\d+$/.test(String(a).trim()) ? parseInt(a, 10) : null),
    monitors: { values: [] },
};
const translateLuaDispatch = new Function("root", `${body}; return translateLuaDispatch;`)(root);

const W = 'window = "address:0x1a2b"'; // 0x1a2b == 6699
const cases = [
    ["move to another space",
     `hl.dsp.window.move({ workspace = 7, follow = false, ${W} })`,
     ["yabai", "-m", "window", "6699", "--space", "7"]],

    ["swap two tiled windows",
     `hl.dsp.window.move({ target = "address:0x2c3d", ${W} })`,
     ["yabai", "-m", "window", "6699", "--warp", "11325"]],

    ["free-position a floating window",
     `hl.dsp.window.move({ x = "120.4", y = "88.6", ${W} })`,
     ["yabai", "-m", "window", "6699", "--move", "abs:120:89"]],

    ["resize by dragging a corner",
     `hl.dsp.window.resize({ dw = 40, dh = -25, ${W} })`,
     ["sh", "-c", "yabai -m window 6699 --resize bottom_right:40:-25 || yabai -m window 6699 --resize top_left:-40:25"]],

    ["focus a space",
     "hl.dsp.focus({ workspace = 3 })",
     ["yabai", "-m", "space", "--focus", "3"]],

    ["close a window",
     `hl.dsp.window.close({ ${W} })`,
     ["yabai", "-m", "window", "6699", "--close"]],
];

for (const [name, cmd, want] of cases) {
    assert.deepEqual(translateLuaDispatch(cmd), want, `${name}\n  ${cmd}`);
    console.log("ok  ", name);
}

// A move with nothing actionable is a deliberate no-op, not a crash.
assert.deepEqual(translateLuaDispatch(`hl.dsp.window.move({ ${W} })`), []);
console.log("ok   bare move is a no-op");

// Anything unmapped must report itself rather than silently doing something.
assert.equal(translateLuaDispatch("hl.dsp.nonsense({})"), null);
console.log("ok   unmapped dispatch returns null");

console.log("\nall passed");
