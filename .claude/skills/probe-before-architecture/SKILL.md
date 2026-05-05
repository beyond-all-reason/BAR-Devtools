---
name: probe-before-architecture
description: When picking between platform-boundary architectures (sync, IPC, build pipeline), build a probe harness that produces real numbers before writing the production code. Use this when someone says "I think X would be faster" or "Y should work" about WSL/Windows/container boundaries — it's the workflow that produced wsl-watchdog-mntc instead of guessing.
---

# Probe before architecture

We picked `wsl-watchdog-mntc` over five other plausible sync architectures because we measured all six end-to-end with `scripts/probe_wsl_sync.py`. The numbers killed alternatives that "felt obvious" (a Windows-side watcher seemed natural — turned out Plan 9 doesn't forward inotify and watchdog silently degrades to polling).

## When this applies

Any time the design space crosses a platform boundary — WSL ↔ Windows, host ↔ container, container ↔ container, process ↔ kernel — and the candidate architectures differ in *what watches*, *what carries the event*, and *what writes*. Don't reason from first principles about whether inotify forwards over Plan 9. Probe it.

## Naming convention

`<watcher-host>-<event-source>-<destination>`:

- watcher-host: where the watcher process runs (`wsl`, `win`, `container`)
- event-source: how it learns about changes (`watchdog`, `inotifywait`, `fsevents`, `detect`, `polling`)
- destination: where the write lands (`mntc` for `/mnt/c`, `unc` for `\\wsl$\...`, `local` for native FS)

This forces clarity. "Use watchman" isn't an architecture; `wsl-watchdog-mntc` with watchman as the delta-query layer is. The naming makes mismatches obvious — if you're considering `win-watchdog-unc`, the destination tells you you're writing through the slow direction.

## What a probe must measure

- **Median + p99 round-trip:** edit on source side → file-content-equal on destination side. Not "first byte arrived"; equality, because partial-write windows matter.
- **Cold-start cost:** seed an empty destination with N files. This is what users feel on first daemon launch.
- **Steady-state cost per event:** after seeding, individual file edits.
- **Failure modes:** kill the watcher mid-edit, fill the watch limit, hit `EACCES` on locked files. The architecture has to survive these, not just benchmark fast on the happy path.

The probe should be *runnable by someone reproducing the decision two years later*. `scripts/probe_wsl_sync.py` is the template.

## Pre-conditions are part of the probe

If `wsl-watchdog-mntc` requires `fs.inotify.max_user_watches=524288`, the probe documents that and the production code must enforce it (`ensure_sync_daemon_deps_wsl`). A probe that succeeds because of sysctl tweaks the production never makes is a lie.

## Document the rejected arms

Killed candidates go in the design doc with their numbers and the *reason* they lost — not "we picked iv, ignore the rest". The next contributor proposing a Windows-side watcher needs to find the row that says `(iii) win-watchdog-unc — 850ms median, native fsevents not forwarded by Plan 9, ruled out`.

The doc lives in `bar-design-docs/bifurcated_types/dev_setup_restructured.md`.

## When to re-probe

- WSL major version change (1 → 2 was an inotify boundary; future changes might shift again).
- Watchdog / Watchman / rsync major version change that touches the OS abstraction layer.
- File count in the watched tree grows by 10×.
- Someone proposes "let's just use X" where X is one of the rejected arms — re-run the probe before deciding the platform changed.

Re-probing is cheap; making the wrong architectural decision and discovering it via user reports is not.
