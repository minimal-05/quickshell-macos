# tests/

Runnable checks for the macOS backend. None of them touch the user's live
shell: every instance a test starts has its own root file under this directory
(quickshell keys the instance on the root path, so a distinct basename is a
distinct instance), and the harness kills only the pid it started.

## Tools

Every tool lives in `Quickshell.app/Contents/Resources/tools` (source:
`src/tools/`) and is reached as `bin/<tool>` (a symlink onto `qs`) or
`qs <tool>`; `qs --tools` lists them.

- `qs-test <root.qml> [--binary p] [--timeout s] -- <target> <fn> [args] [== expected]`
  starts a throwaway instance, waits for `Configuration Loaded`, runs one
  `ipc call`, prints `PASS`/`FAIL` (exit 1 on FAIL), kills the instance.
  `--expect-log 'regex'` asserts on the log instead; `--shell` starts the
  instance, prints its pid and leaves it running for multi-step drivers
  (that is how `qs-probe` uses it). Refuses `shell.qml`, `settings.qml`,
  `finder.qml` by basename. The binary is this tree's
  `Quickshell.app/Contents/MacOS/quickshell`; `QS_BINARY` points a run at
  another build, such as a worktree's.
- `qs-probe` — the hover enter/leave table, built on `qs-test --shell`.
- `qs-perf [pid] [seconds]` — self CPU, reaped-children CPU, spawns/s,
  interrupt wakeups/s, footprint, orphan adapters, dead instance dirs; one
  JSON line per run appended to `tests/perf-history.jsonl`.
  `qs-perf --children` prints the histogram of child command lines instead.
  Audit baselines live in `tests/perf-baseline.json`.
- `qs-reap [--dry-run]` — kills orphan `mediaremote-adapter.pl` helpers and
  prunes dead `$XDG_RUNTIME_DIR/quickshell` instance dirs. Run by `qs-dev`
  and `qs-start`.

## Checks

| file | what it asserts | run |
|---|---|---|
| `hoverprobe.qml` | a PanelWindow's MouseArea sees the pointer enter/leave | `bin/qs-test tests/hoverprobe.qml -- probe hover outside`, or `bin/qs-probe` for the full table |
| `hoverprobe-focusable.qml` | same, for a focusable panel | `QS_PROBE_QML=tests/hoverprobe-focusable.qml bin/qs-probe` |
| `swapchain.sh` + `swapchain.qml` | a full-height panel's IOSurface (`vmmap --summary`) goes back to the idle figure once it has been hidden past the release timer, renders again on re-show (`frameSwapped` keeps counting), releases again on the next hide; `animate: false` unmaps at once while an animated panel stays mapped through its close | `bash tests/swapchain.sh` (`QS_BINARY` overrides the binary) |
| `mask.sh` + `mask.qml` | `PanelWindow.mask` is a hit-test region: a full-width panel with a 200x100 mask hovers only inside the mask (pointer moved by `warp.py`), an empty mask never hovers, no mask hovers everywhere; the window server (`CGWindowListCopyWindowInfo` via JXA) reports the full panel bounds at alpha 1 throughout | `bash tests/mask.sh` (`QS_BINARY` overrides the binary) |
| `reservation.sh` + `reservation.qml` | the backend sums visible panels' `exclusiveZone` per edge into `Quickshell.Cocoa.Reservation` and, once `applyToYabai` is on, writes `yabai -m config external_bar all:<top>:<bottom>` itself: a top panel with zone 40 reads `all:40:0`, moved to the bottom `all:0:40`, hidden `all:0:0` | `bash tests/reservation.sh` (`QS_BINARY` overrides the binary; saves and restores external_bar and the four paddings in a trap -- it moves the user's windows while it runs) |
| `focus.sh` + `focus.qml` | a `focusable: true` panel takes activation on show (`lsappinfo front` is the probe, `Window.active` true) and hands it back to the previously frontmost app within 500 ms of hide; starting the probe leaves the front app alone | `bash tests/focus.sh` (`QS_BINARY` overrides the binary; puts the original front app back in a trap) |
| `reap.sh` | `qs-reap` removes exactly dead dirs and orphan adapters, in a private runtime dir | `bash tests/reap.sh` |
| `bundle.sh` + `_probe_bundle.qml` | `Quickshell.app` is signed with id `org.quickshell.shell` and the usage strings; `bin/qs` is a script (not a symlink) onto the bundle Mach-O and no `bin/quickshell` wrapper remains; an instance started through `bin/qs` runs that Mach-O; ipc reaches it through `qs` and through the bare Mach-O with no environment; `qs-test` works end to end | `bash tests/bundle.sh` (always this tree's bundle; `QS_BINARY` is not consulted) |
| `one-binary.sh` | the one-binary layout: `bin/` is `qs` + `.gitignore` + symlinks; `qs --tools` matches `src/tools/`; every tool execs the same file through `bin/<t>` and `qs <t>` (`QS_TOOL_DRY_RUN`) and prints the same `--help` where safe; the Mach-O run as `hyprctl` is hyprctl; an instance started from an empty environment reports the PATH/XDG_RUNTIME_DIR/QML2_IMPORT_PATH the binary set; `qs ipc` reaches it; `qs-probe` 5/5 through `bin/qs` | `bash tests/one-binary.sh` (always this tree's bundle) |
| `notifications.sh` | notify-send v2 wire protocol: `-A/-i/-u/-c/-h/-t` reach `Notification`, action invoke round-trips to the sender, `-r` replaces in place, `tracked=false` dismisses, `-w` returns on close, unclaimed notifications are dropped | `bash tests/notifications.sh` (`QS_BINARY` overrides the binary) |
| `sysstats.sh` + `_probe_resourceusage.qml` | `qs-sysstats` (compiled from `src/tools/qs-sysstats.c` into the bundle) emits the CPU-tick/memory/swap JSON `services/ResourceUsage.qml` diffs (ticks are cumulative, `bin/qs-sysstats` reaches the same tool), and the service turns two samples into a CPU% with no `top` child | `bash tests/sysstats.sh` (`QS_CONFIG_ROOT`, `QS_BINARY` to point at a config checkout / built binary) |
| `native-stats-power.sh` + `_probe_sysstats.qml`, `_probe_power.qml` | the in-process singletons: `Quickshell.Cocoa.SystemStats` ticks only grow, `memTotal == hw.memsize`, used + available == total, `sample()` emits; `Quickshell.Cocoa.Power` percentage/state/lowPowerMode match `pmset`, energy and rate are sane; the UPower shim answers on top of it with no settle; `services/ResourceUsage.qml` samples through it; `qs-perf --children` sees 0 children under every one of them | `bash tests/native-stats-power.sh` (`QS_BINARY`, `QS_CONFIG_ROOT`, `PERF=<seconds>`) |
| `standins.sh` | every verb of the Linux-tool stand-ins (`hyprctl`, `hyprsunset`, `loginctl`/`systemctl`/`reboot`, `ydotool`, `secret-tool`, `checkupdates`), each through its `bin/` symlink: session and key verbs via `--dry-run`, gamma on a private socket, Night Shift and the focused Space put back | `bash tests/standins.sh` (`STANDINS_NO_SPACE=1` skips the Space switch) |
| `native-audio.sh` + `_probe_audio.qml` | the Pipewire shim on the in-process CoreAudio singleton: default sink/source and device lists match `SwitchAudioSource`, volume/mute match `osascript`, a node write is visible to osascript at once, an osascript change lands on the node through the HAL listener within 500 ms, and the user's volume/mute are restored exactly | `bash tests/native-audio.sh` (`QS_BINARY` for a worktree build, `PERF=40` for a spawn histogram: expect 0 osascript/SwitchAudioSource) |
| `hotkeys.sh` + `_probe_hotkeys.qml` | `GlobalShortcut` fires from a real chord: with a private `QS_SHORTCUTS` table and `SKHD_RC`, a CGEvent-posted `ctrl+alt+cmd+shift+z` reaches `pressed`/`released` (both instances of a name), a held key reports the press first, a chord skhd binds is left to skhd, a bare modifier and an unknown key are refused and logged, the `gs_*` IPC route still works | `bash tests/hotkeys.sh` (`QS_BINARY` overrides the binary; python3 needs Accessibility to post keys) |
| `clipboard.sh` + `_probe_clipboard.qml` | `pbcopy` in another process fires `Quickshell.clipboardTextChanged` within 1.5 s with a fresh `clipboardText`; `bin/cliphist` `list`/`decode`/`delete`/`delete-query`/`wipe` in cliphist's shape (newest first, deduplicated, ids never reused, image entries as `[[ binary data .. png WxH ]]`); `bin/wl-copy`/`bin/wl-paste` text and `-t image/png` round trips; a set from QML is recorded and signalled once. Uses a private `QS_CLIPHIST_DIR` and puts the clipboard back | `bash tests/clipboard.sh` (`QS_BINARY` overrides the binary) |
| `shims.sh` | the UPower, Bluetooth, Mpris and kirigami Icon shims answer with the shape consumers read (`_probe_*.qml`, one throwaway instance each) | `bash tests/shims.sh [upower bluetooth mpris kirigami]`; `QS_BINARY=... PERF=40` for a worktree and a spawn histogram |

Add a `_probe_<name>.qml` (with `IpcHandler` functions returning strings) or
a `tests/<name>.sh` for every non-trivial branch of logic; the verifier runs
them.
