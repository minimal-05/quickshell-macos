# quickshell-macos

Fork of `quickshell-mirror/quickshell` with a macOS Cocoa backend, plus the
launcher scripts that drive it. Upstream history is intact — the macOS work is
commits on top, not a patch.

## Where things go

- **C++ / Cocoa backend** → `src/cocoa/`. Rebuild with `bin/qs-build`.
- **Tools** — the Linux-command stand-ins (`hyprctl`, `notify-send`, `pidof`,
  …), the `qs-*` launchers and dev loop, and the C helpers (`menus.c`,
  `qs-sysstats.c`) → `src/tools/`. Anything executable there, plus one tool
  per `*.c`, is installed by `qs-bundle` into
  `Quickshell.app/Contents/Resources/tools/`; `bin/<tool>` symlinks are
  generated from that. A new tool is a new file in `src/tools/`, nothing else.
- **Shims** → `shims/`.
- **Shell config (bar, pills, services)** is *not* here. It lives in
  `~/.config/quickshell` (flat: `shell.qml`, `settings.qml`, `finder.qml` at
  the top), in the `darwin-dotfiles` repo. Refer to it by that path in full;
  the `./shell` and `./examples/` symlinks that used to stand in for it are
  gone, and nothing here should grow a new one.

## One binary: `qs` is the Mach-O

`Quickshell.app/Contents/MacOS/quickshell` is the shell and every tool. On
start it sets the three things macOS does not give quickshell for free (PATH
with the bundle's tools dir first, XDG_RUNTIME_DIR, QML2_IMPORT_PATH), then
looks at the name it was started under (`src/launch/tools.cpp`):

- `basename(argv[0])` names a tool → `execv` of
  `Contents/Resources/tools/<name>` (that is what `bin/hyprctl -> qs` does:
  `bin/qs` is a script that `exec -a`s the Mach-O with the symlink's name);
- `qs <tool> [args]` → the same;
- `qs --tools` → the list;
- otherwise it is quickshell. With a `shell.qml` directly in
  `~/.config/quickshell` (the layout in use) nothing is set and quickshell's
  own "default" finds it; only where `~/.config/quickshell/end4/shell.qml`
  exists instead does `QS_CONFIG_NAME` default to `end4`. Neither applies when
  `-c`/`-p`/`-m` was given or `QS_CONFIG_PATH` is in the environment (that is
  how `qs-ipc` is pointed at a test probe).

Everything runs through it — end-4's QML (which calls `qs`, `hyprctl`,
`notify-send` by bare name), skhd and karabiner via `bin/qs-ipc`, launchd via
`bin/qs-start`. That config default is why nothing else names a config path;
to point a launcher at another config directory, set `QS_CONFIG_NAME=<name>`
— do not add a `-p`.

`bin/qs` stays a script rather than a symlink because NSBundle resolves the
bundle from the executable's real path, so nothing may stand between the
process and the Mach-O. `install.sh` writes `~/.local/bin/qs` as an exec
wrapper onto it, which is the whole install.

## Not committed, but on disk

`Quickshell.app/` (generated in full by `qs-bundle`: Info.plist, the Mach-O,
the tools copied or compiled from `src/tools/`), the `bin/<tool>` symlinks
(`bin/.gitignore`) and `build/`. All gitignored on purpose; don't "fix" them
by adding them.

`bin/qs` is the opposite: it used to be generated and gitignored, which left the
one command everything calls with no history and absent from a fresh checkout.
It is committed now. Don't re-ignore it. In a fresh checkout it is the only
thing in `bin/`; `bin/qs qs-build` runs the build tool from `src/tools/` until
the bundle exists.

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
- Tools are **exec'd from inside the bundle**, so an edit to `src/tools/x` is
  not live until `qs-dev --no-build` (or `qs-bundle`) copies it back in. That
  includes `qs-build` and `qs-bundle` themselves: `bin/qs-build` runs the
  installed copy, which then installs the edited one.
- A tool must not be named `log`, `list`, `kill`, `ipc` or `msg`: quickshell's
  own subcommands win.
- Never hardcode a `~/.claude/jobs/*/tmp` path here. Those are scratch dirs
  deleted with the job; two scripts used to build from one.
- `karabiner.json` and `skhdrc` call `bin/qs-ipc` by **absolute path**, and
  launchd calls `bin/qs-start`. Those are the generated symlinks; keep the
  names. Moving this repo means updating both files.
