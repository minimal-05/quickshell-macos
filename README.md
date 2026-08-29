# quickshell-macos

A macOS port of [Quickshell](https://quickshell.outfoxxed.me) — a Cocoa
platform backend for the C++ engine, QML shims for the Linux-only modules, and
the launcher scripts that tie it into a real desktop.

This is a fork of
[quickshell-mirror/quickshell](https://github.com/quickshell-mirror/quickshell).
Upstream's history is intact; the macOS work sits on top of it. Same licence as
upstream (**GPL-3.0**) — see [LICENSE](LICENSE) and [LICENSE-GPL](LICENSE-GPL).
Upstream docs: [BUILD.md](BUILD.md), [HACKING.md](HACKING.md).

## Install

```sh
git clone https://github.com/minimal-05/quickshell-macos.git ~/Projects/quickshell-macos
cd ~/Projects/quickshell-macos && ./install.sh
```

Builds the engine, code-signs it, and drops it at `bin/quickshell`.

## What's here

| | |
|---|---|
| `src/cocoa/` | the macOS platform backend — panels, layer-shell equivalent, focus grabs, app icons |
| `shims/` | QML stand-ins for `Quickshell.Hyprland`, `Quickshell.Bluetooth` and friends |
| `bin/qs-*` | launchers: build, dev-loop, IPC, notification bridge, palette generation |
| `PLATFORM.md` | **read this to extend the port** — where the platform seam is, what must be C++ |

Everything else is upstream.

## Running a shell

`bin/qs-switch mine` runs the config at `~/.config/quickshell`, which lives in
my [darwin-dotfiles](https://github.com/minimal-05/darwin-dotfiles).

## Development

```sh
bin/qs-dev              # rebuild if sources changed, reinstall, restart
bin/qs-dev --no-build   # QML-only edits need nothing built
```

## Notes

- The build is ad-hoc code-signed. Copying a Mach-O binary invalidates its
  signature and the kernel then kills it on exec **with no output at all**, so
  `qs-build` re-signs every time. If Quickshell dies silently, check that first.
- Media keys are grabbed by Karabiner and routed to `bin/qs-ipc`, which is why
  macOS never draws its own volume/brightness HUD. The OSD is signal-driven, so
  new bindings belong at the key, not at the HUD.
- The shell config (end-4's illogical-impulse, adapted) is **not** here. It
  lives in `~/.config/quickshell`, tracked in `darwin-dotfiles`. Upstream it is
  [end-4/dots-hyprland](https://github.com/end-4/dots-hyprland); note that our
  copy is flattened — `modules/bar`, not `modules/ii/bar`.
