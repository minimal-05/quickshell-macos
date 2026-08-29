# quickshell-macos

Fork of `quickshell-mirror/quickshell` with a macOS Cocoa backend, plus the
launcher scripts that drive it. Upstream history is intact — the macOS work is
commits on top, not a patch.

## Where things go

- **C++ / Cocoa backend** → `src/cocoa/`. Rebuild with `bin/qs-build`.
- **Launchers, shims, dev loop** → `bin/`, `shims/`.
- **Shell config (bar, pills, services)** is *not* here. It lives in
  `~/.config/quickshell`, in the `darwin-dotfiles` repo. Refer to it by that
  path in full — the `./shell` and `./examples/` symlinks that used to stand in
  for it are gone, and nothing here should grow a new one.

## Not committed, but on disk

`bin/quickshell` (built binary), `bin/qs-sysstats.bin` (the compiled
`src/tools/qs-sysstats.c` helper; `bin/qs-sysstats` falls back to the python
version when it is missing) and `build/`. All gitignored on purpose; don't
"fix" them by adding them.

`examples/` used to hold end-4's config, untracked, with no history. On
2026-08-29 it moved to `~/.config/quickshell`, where it is tracked in
`darwin-dotfiles`, and the directory was removed rather than left as a symlink.
Write paths to the config as `$HOME/.config/quickshell`.

`bin/qs` is a two-line exec wrapper around `bin/quickshell`, not a symlink:
end-4's QML calls `qs` by bare name in a dozen places and needs it on PATH.

## Gotchas

- Copying the binary invalidates its ad-hoc signature and the kernel kills it on
  exec **with no output**. Re-sign after any copy: `codesign -f -s - bin/quickshell`.
- Never hardcode a `~/.claude/jobs/*/tmp` path here. Those are scratch dirs
  deleted with the job; two scripts used to build from one.
- `karabiner.json` and `skhdrc` call `bin/qs-ipc` by **absolute path**. Moving
  this repo means updating both.
