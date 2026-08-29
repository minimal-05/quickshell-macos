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
  `finder.qml` by basename. `QS_BINARY` overrides the binary for worktrees
  that have not built `bin/quickshell`.
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
| `standins.sh` | every verb of the Linux-tool stand-ins (`hyprctl`, `hyprsunset`, `loginctl`/`systemctl`/`reboot`, `ydotool`, `secret-tool`, `checkupdates`): session and key verbs via `--dry-run`, gamma on a private socket, Night Shift and the focused Space put back | `bash tests/standins.sh` (`STANDINS_NO_SPACE=1` skips the Space switch) |

Add a `_probe_<name>.qml` (with `IpcHandler` functions returning strings) or
a `tests/<name>.sh` for every non-trivial branch of logic; the verifier runs
them.
