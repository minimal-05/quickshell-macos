# quickshell-macos

Fork of `quickshell-mirror/quickshell` with a macOS Cocoa backend, plus the
launcher scripts that drive it. Upstream history is intact — the macOS work is
commits on top, not a patch.

## Where things go

- **C++ / Cocoa backend** → `src/cocoa/`. Rebuild with `bin/qs-build`.
- **Launchers, shims, dev loop** → `bin/`, `shims/`.
- **Shell config (bar, pills, services)** is *not* here. It lives in
  `~/.config/quickshell`, in the `darwin-dotfiles` repo. `./shell` is a symlink
  to it — do not replace it with a directory.

## Not committed, but on disk

`bin/quickshell` (built binary), `build/`, and `examples/end4-ii` (end-4's
illogical-impulse config — third party, its own licence). All gitignored on
purpose; don't "fix" them by adding them.

## Gotchas

- Copying the binary invalidates its ad-hoc signature and the kernel kills it on
  exec **with no output**. Re-sign after any copy: `codesign -f -s - bin/quickshell`.
- Never hardcode a `~/.claude/jobs/*/tmp` path here. Those are scratch dirs
  deleted with the job; two scripts used to build from one.
- `karabiner.json` and `skhdrc` call `bin/qs-ipc` by **absolute path**. Moving
  this repo means updating both.
