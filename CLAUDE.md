# quickshell-macos

Fork of `quickshell-mirror/quickshell` with a macOS Cocoa backend, plus the
launcher scripts that drive it. Upstream history is intact — the macOS work is
commits on top, not a patch.

## Where things go

- **C++ / Cocoa backend** → `src/cocoa/`. Rebuild with `bin/qs-build`.
- **Launchers, shims, dev loop** → `bin/`, `shims/`.
- **Helper binaries** → `helpers/`. Built by `qs-build` into `bin/`.
- **Shell configs** are *not* here. They live in `~/.config/quickshell/<name>`,
  in the `darwin-dotfiles` repo — `end4` and `mine`. Refer to them by path in
  full; the `./shell` and `./examples/` symlinks that used to stand in for them
  are gone, and nothing here should grow a new one.

## `bin/qs` is the entry point

Everything runs through it — the launchers here, end-4's QML (which calls `qs`
by bare name), skhd and karabiner via `qs-ipc`, and launchd via `qs-start`. It
sets the three things macOS does not give quickshell for free (PATH,
XDG_RUNTIME_DIR, QML2_IMPORT_PATH), defaults `QS_CONFIG_NAME` to `end4`, and
execs the binary **inside Quickshell.app**.

That default is why nothing else names a config path any more. To point a
launcher at the other config, set `QS_CONFIG_NAME=mine` — do not add a `-p`.

`install.sh` writes `~/.local/bin/qs` as an exec wrapper onto it, which is the
whole install. A wrapper rather than a symlink: NSBundle resolves the bundle
from the executable's real path, so nothing may stand between the process and
`Quickshell.app/Contents/MacOS/quickshell`.

## Not committed, but on disk

`Quickshell.app/` (generated in full by `bin/qs-bundle`), `bin/quickshell` (now
a wrapper onto the bundle), `bin/menus` (built from `helpers/menus`) and
`build/`. All gitignored on purpose; don't "fix" them by adding them.

`bin/qs` is the opposite: it used to be generated and gitignored, which left the
one command everything calls with no history and absent from a fresh checkout.
It is committed now. Don't re-ignore it.

`examples/` used to hold end-4's config, untracked, with no history. On
2026-08-29 it moved to `~/.config/quickshell`, where it is tracked in
`darwin-dotfiles`, and the directory was removed rather than left as a symlink.
Write paths to the config as `$HOME/.config/quickshell`.

## Gotchas

- Copying a Mach-O invalidates its signature and the kernel kills it on exec
  **with no output**. `bin/qs-bundle` re-signs every time; go through it rather
  than copying the binary by hand.
- TCC keys Screen Recording, Accessibility and Full Disk Access on the bundle id
  plus the signing certificate. That is the whole reason the binary lives in
  `Quickshell.app` — a bare ad-hoc binary's identity is its cdhash, so every
  grant died at the next build. Never change `CFBundleIdentifier`.
- Never hardcode a `~/.claude/jobs/*/tmp` path here. Those are scratch dirs
  deleted with the job; two scripts used to build from one.
- `karabiner.json` and `skhdrc` call `bin/qs-ipc` by **absolute path**. Moving
  this repo means updating both.
