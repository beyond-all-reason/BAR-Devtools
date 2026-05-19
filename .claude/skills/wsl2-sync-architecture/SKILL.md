---
name: wsl2-sync-architecture
description: Hard-won facts about the WSL2 ↔ Windows sync daemon (sync.py, sync.sh, launch.sh). Read this before changing how files cross the WSL/Windows boundary, before adjusting watchman/rsync invocations, before "improving" the cold-copy path, or before proposing a different sync architecture.
---

# WSL2 sync architecture

## Architecture name

`wsl-watchdog-mntc`. The convention is `<watcher-host>-<event-source>-<destination>`:

- watcher-host: where the watcher process runs (`wsl` or `win`)
- event-source: how it learns about changes (`watchdog`, `inotifywait`, `detect`)
- destination: where it writes (`mntc` = `/mnt/c`, `unc` = `\\wsl$\...`)

When proposing or evaluating a sync change, name it this way. We picked (iv) `wsl-watchdog-mntc` from a probe set that included (iii) `win-watchdog-unc`, (v) `wsl-detect-win-copy`, (vi) `wsl-inotifywait-mntc`. Probe data lives in `bar-design-docs/bifurcated_types/dev_setup_restructured.md`.

## Boundary facts (do not relitigate without a fresh probe)

- **Plan 9 does not forward inotify across the WSL/Windows boundary.** A native watchdog Observer on the Windows side watching `\\wsl$\...` silently degrades to `PollingObserver` (stat-loop). Production must run the watcher on the Linux side.
- **`/mnt/c` ≠ NTFS native.** drvfs adds per-stat round-trips. `rsync` against `/mnt/c` is correct but slow (~80s stat-walk on the BAR tree). That's why we use Watchman to skip the walk.
- **Windows holds DLL handles.** When `spring.exe` or `Beyond-All-Reason.exe` is running, rsync from Linux through drvfs to engine DLLs hits `EACCES` (rsync exit 23). `bar::stop` (`launch.sh`'s `stop_wsl`) kills these holders before `engine::build` runs.
- **mmap inode stability.** The engine mmaps Lua sources. If a sync replaces the file via tempfile + rename, the inode flips under the live mmap and the engine reads garbage. **Always use `rsync --inplace`** for cold copies and `_copy_inplace` for per-event mirrors. Never `shutil.move` or rename-into-place.
- **inotify watch limits.** Default 8192 is below BAR's directory count. `setup::init` bumps `fs.inotify.max_user_watches` to 524288 via `/etc/sysctl.d/99-bar-devtools.conf`.

## Watchman is mandatory, no fallback

- Watchman lives **inside the bar-dev distrobox** (installed by `dev.Containerfile`), exported to host PATH via `distrobox-export`. The host wrapper at `~/.local/bin/watchman` runs `distrobox enter -- watchman`.
- `sync.py:_cold_copy` calls `_cold_copy_via_watchman` directly. There is no `_have_watchman()` guard. If watchman isn't on PATH, `subprocess.run(["watchman", ...])` raises `FileNotFoundError` — that's the loud failure we want, not a silent ~80s rsync stat-walk that contributors mistake for normal.
- First call for a `(src, dst)` pair: `watch-project` + initial `clock` + full rsync seed. Subsequent calls: `since <clock>` query + rsync `--files-from` for changed files only + unlink for deletions.
- Pair state is persisted to `${XDG_STATE_HOME:-~/.local/state}/bar-devtools/sync-state-<sha1>.json` via atomic rename + fsync. (Lives on Linux ext4 — NOT under `$BAR_DATA_DIR` on /mnt/c — so watchman clock tokens survive daemon restarts without paying drvfs costs every read.)

## Watchman / Fedora / RPM ABI

The watchman RPM Meta publishes is built against a specific Fedora release. **Pin `dev.Containerfile`'s base image to the same Fedora version.** As of `v2026.05.04.00` that's `fedora:42` (boost 1.83, libglog.so.0, libdwarf.so.0). Bumping to `fedora:latest` will break the install with "nothing provides libboost_context.so.1.83.0" et al. When bumping watchman: bump the FROM line in lockstep.

## Daemon lifecycle

- `sync.sh start [--wait-ready]` — spawns one `sync.py` per pair; readiness is the `READY` line in the log. `--wait-ready` tails the log and blocks until ready or the daemon dies.
- `sync.sh stop` — SIGTERM, then SIGKILL.
- **Validate pair list before "already running" early-return.** A stale pid file with a daemon already up should not skip pair validation; otherwise a missing source symlink stays silent.
- **Drift detection.** If the pair list passed to `start` differs from the pair list the running daemon was started with, restart the daemon.
- The engine pair is excluded from the watcher because `engine::build` rsyncs into the same target. A live watcher would race the build.

## Logging discipline

- One `FileHandler` only when `--log` is set. Adding a `StreamHandler(stderr)` while shell redirects stderr to the log file double-writes every line.
- Per-event mirrors log at `INFO` (not `DEBUG`) — the user wants to see what synced.
- Startup line includes the inotify watch limit, the chosen Observer class (native vs polling), and the watchman version.
- Signals are logged by name (`SIGTERM (kill)`, `SIGINT (Ctrl-C)`, `SIGHUP (terminal closed)`) with recovery hints (`just bar::stop`, `just link::create`) — never just "received signal 15".

## Re-probing the sync decision

`wsl-watchdog-mntc` was picked by measuring all six candidate architectures end-to-end with `scripts/probe_wsl_sync.py` — not by reasoning from first principles. A Windows-side watcher *felt* obvious; Plan 9 not forwarding inotify is what killed it. Don't relitigate the boundary facts above from a comment thread — re-run the probe.

Re-probe when:

- WSL has a major version change (1 → 2 was an inotify boundary; a future one might shift again).
- Watchdog / Watchman / rsync has a major bump touching the OS abstraction layer.
- The watched tree's file count grows ~10×.
- Someone proposes "just use X" where X is one of the rejected arms — re-run before deciding the platform changed.

A probe that earns a decision measures, on real hardware:

- **Median + p99 round-trip** — edit on source → *content-equal* on destination. Equality, not first-byte: partial-write windows matter.
- **Cold-start cost** — seed an empty destination with N files; this is what users feel on first daemon launch.
- **Steady-state per-event cost** — individual edits after the seed.
- **Failure modes** — kill the watcher mid-edit, exhaust the watch limit, hit `EACCES` on locked files. The architecture has to survive these, not just win the happy-path benchmark.

And it documents its preconditions: if the result depends on `fs.inotify.max_user_watches=524288`, production must enforce that (`ensure_sync_daemon_deps_wsl`) — a probe that passes only because of a sysctl production never sets is a lie. Keep `scripts/probe_wsl_sync.py` runnable so the decision stays reproducible; killed candidates and their numbers live in `bar-design-docs/bifurcated_types/dev_setup_restructured.md`.
