# tests/

Runnable checks for the macOS backend. None of them touch the user's live
shell: every instance a test starts has its own root file under this directory
(quickshell keys the instance on the root path, so a distinct basename is a
distinct instance), and the harness kills only the pid it started.

## Tools (in `bin/`)

- `qs-test <root.qml> [--binary p] [--timeout s] -- <target> <fn> [args] [== expected]`
  starts a throwaway instance, waits for `Configuration Loaded`, runs one
  `ipc call`, prints `PASS`/`FAIL` (exit 1 on FAIL), kills the instance.
  `--expect-log 'regex'` asserts on the log instead; `--shell` starts the
  instance, prints its pid and leaves it running for multi-step drivers
  (that is how `qs-probe` uses it). Refuses `shell.qml`, `settings.qml`,
  `finder.qml` by basename. The binary is `bin/qs` (which execs the bundle
  binary); `QS_BINARY` points a run at another build, such as a worktree's
  `Quickshell.app/Contents/MacOS/quickshell`.
- `qs-probe` — the hover enter/leave table, built on `qs-test --shell`.
- `qs-perf [pid] [seconds]` — self CPU, reaped-children CPU, spawns/s,
  interrupt wakeups/s, footprint, orphan adapters, dead instance dirs; one
  JSON line per run appended to `tests/perf-history.jsonl`.
  `qs-perf --children` prints the histogram of child command lines instead.
  Audit baselines live in `tests/perf-baseline.json`.
- `qs-reap [--dry-run]` — kills orphan `mediaremote-adapter.pl` helpers and
  prunes dead `$XDG_RUNTIME_DIR/quickshell` instance dirs. Run by `qs-dev`
  and `qs-start`.
- `qs-spawns <pid> [seconds] [-v]` — every process spawned under an instance,
  by name, polled from libproc at 1 ms so the 10 ms `yabai`/`jq` children
  `qs-perf` misses are counted. `-v` prints each one as it appears.
- `qs-yabai-signals install|remove|status` — the yabai signals behind the
  Hyprland/ToplevelManager shims (one `touch` of
  `$XDG_RUNTIME_DIR/quickshell/yabai/<event>` per event). The shims install
  them on start; `status` shows what yabai holds.

## Checks

| file | what it asserts | run |
|---|---|---|
| `hoverprobe.qml` | a PanelWindow's MouseArea sees the pointer enter/leave | `bin/qs-test tests/hoverprobe.qml -- probe hover outside`, or `bin/qs-probe` for the full table |
| `hoverprobe-focusable.qml` | same, for a focusable panel | `QS_PROBE_QML=tests/hoverprobe-focusable.qml bin/qs-probe` |
| `reap.sh` | `qs-reap` removes exactly dead dirs and orphan adapters, in a private runtime dir | `bash tests/reap.sh` |
| `bundle.sh` + `_probe_bundle.qml` | `Quickshell.app` is signed with id `org.quickshell.shell` and the usage strings; `bin/quickshell` is a script wrapper (not a symlink) onto the bundle Mach-O; an instance started through `bin/qs` runs that Mach-O; ipc reaches it through `qs` and through the wrapper; `qs-test` works end to end | `bash tests/bundle.sh` (always this tree's bundle; `QS_BINARY` is not consulted) |
| `notifications.sh` | notify-send v2 wire protocol: `-A/-i/-u/-c/-h/-t` reach `Notification`, action invoke round-trips to the sender, `-r` replaces in place, `tracked=false` dismisses, `-w` returns on close, unclaimed notifications are dropped | `bash tests/notifications.sh` (`QS_BINARY` overrides the binary) |
| `sysstats.sh` + `_probe_resourceusage.qml` | `bin/qs-sysstats` emits the CPU-tick/memory/swap JSON `services/ResourceUsage.qml` diffs (binary and python fallback agree, ticks are cumulative), and the service turns two samples into a CPU% with no `top` child | `bash tests/sysstats.sh` (`QS_CONFIG_ROOT`, `QS_BINARY` to point at a config checkout / built binary) |
| `standins.sh` | every verb of the Linux-tool stand-ins (`hyprctl`, `hyprsunset`, `loginctl`/`systemctl`/`reboot`, `ydotool`, `secret-tool`, `checkupdates`): session and key verbs via `--dry-run`, gamma on a private socket, Night Shift and the focused Space put back | `bash tests/standins.sh` (`STANDINS_NO_SPACE=1` skips the Space switch) |
| `shims.sh` | the UPower, Bluetooth, Mpris and kirigami Icon shims answer with the shape consumers read (`_probe_*.qml`, one throwaway instance each) | `bash tests/shims.sh [upower bluetooth mpris kirigami]`; `QS_BINARY=... PERF=40` for a worktree and a spawn histogram |
| `yabai-events.sh` + `_probe_hyprland.qml` | the yabai-signal path: workspaces/toplevels populate, `hl.dsp.global` fires an in-process GlobalShortcut, `HyprlandToplevel.wayland` resolves, `qs_*` signals register once, an idle instance runs nothing periodic (`qs-spawns`), a Space switch reaches `focusedWorkspace` within 50 ms of the signal file's mtime for one space query and one window query | `bash tests/yabai-events.sh` (`YE_NO_SPACE=1` skips the Space switch; `QS_BINARY` for a worktree). Removes the signals afterwards only if none were registered before |

Add a `_probe_<name>.qml` (with `IpcHandler` functions returning strings) or
a `tests/<name>.sh` for every non-trivial branch of logic; the verifier runs
them.
