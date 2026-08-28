# quickshell-src — C++ / Cocoa backend only

Upstream `quickshell-mirror/quickshell` plus our **unpushed macOS Cocoa backend**
(4 commits on top of upstream, plus uncommitted work in `src/cocoa/`).

Rescued on 2026-08-28 from a Claude job scratch dir that would have been deleted
with the job. Nothing but this checkout has that work — **do not delete, and push
it somewhere.**

- Shell config is *not* here. It is in `~/.config/quickshell`.
- Build/run loop: `~/Projects/quickshell-macos/bin/qs-dev` (builds from here).
- Full layout: `~/.config/CLAUDE.md`.

`~/Projects/qs-macos-spike` is the older checkout *without* the Cocoa backend.
Prefer this one.
