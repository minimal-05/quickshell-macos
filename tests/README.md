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

## Checks

| file | what it asserts | run |
|---|---|---|
| `hoverprobe.qml` | a PanelWindow's MouseArea sees the pointer enter/leave | `bin/qs-test tests/hoverprobe.qml -- probe hover outside`, or `bin/qs-probe` for the full table |
| `hoverprobe-focusable.qml` | same, for a focusable panel | `QS_PROBE_QML=tests/hoverprobe-focusable.qml bin/qs-probe` |
| `reap.sh` | `qs-reap` removes exactly dead dirs and orphan adapters, in a private runtime dir | `bash tests/reap.sh` |
| `bundle.sh` + `_probe_bundle.qml` | `Quickshell.app` is signed with id `org.quickshell.shell` and the usage strings; `bin/quickshell` is a script wrapper (not a symlink) onto the bundle Mach-O; an instance started through `bin/qs` runs that Mach-O; ipc reaches it through `qs` and through the wrapper; `qs-test` works end to end | `bash tests/bundle.sh` (always this tree's bundle; `QS_BINARY` is not consulted) |
| `notifications.sh` | notify-send v2 wire protocol: `-A/-i/-u/-c/-h/-t` reach `Notification`, action invoke round-trips to the sender, `-r` replaces in place, `tracked=false` dismisses, `-w` returns on close, unclaimed notifications are dropped | `bash tests/notifications.sh` (`QS_BINARY` overrides the binary) |
| `sysstats.sh` + `_probe_resourceusage.qml` | `bin/qs-sysstats` (the script-facing helper) emits the CPU-tick/memory/swap JSON (binary and python fallback agree, ticks are cumulative), and `services/ResourceUsage.qml` turns two samples into a CPU% with no `top` child | `bash tests/sysstats.sh` (`QS_CONFIG_ROOT`, `QS_BINARY` to point at a config checkout / built binary) |
| `native-stats-power.sh` + `_probe_sysstats.qml`, `_probe_power.qml` | the in-process singletons: `Quickshell.Cocoa.SystemStats` ticks only grow, `memTotal == hw.memsize`, used + available == total, `sample()` emits; `Quickshell.Cocoa.Power` percentage/state/lowPowerMode match `pmset`, energy and rate are sane; the UPower shim answers on top of it with no settle; `services/ResourceUsage.qml` samples through it; `qs-perf --children` sees 0 children under every one of them | `bash tests/native-stats-power.sh` (`QS_BINARY`, `QS_CONFIG_ROOT`, `PERF=<seconds>`) |
| `standins.sh` | every verb of the Linux-tool stand-ins (`hyprctl`, `hyprsunset`, `loginctl`/`systemctl`/`reboot`, `ydotool`, `secret-tool`, `checkupdates`): session and key verbs via `--dry-run`, gamma on a private socket, Night Shift and the focused Space put back | `bash tests/standins.sh` (`STANDINS_NO_SPACE=1` skips the Space switch) |
| `shims.sh` | the UPower, Bluetooth, Mpris and kirigami Icon shims answer with the shape consumers read (`_probe_*.qml`, one throwaway instance each) | `bash tests/shims.sh [upower bluetooth mpris kirigami]`; `QS_BINARY=... PERF=40` for a worktree and a spawn histogram |

Add a `_probe_<name>.qml` (with `IpcHandler` functions returning strings) or
a `tests/<name>.sh` for every non-trivial branch of logic; the verifier runs
them.
