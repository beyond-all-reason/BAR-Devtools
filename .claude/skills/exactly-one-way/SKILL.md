---
name: exactly-one-way
description: There should be exactly one way to do everything in this repo. Use this when reviewing or refactoring setup/sync code — it's the rule that drove removing `cmd_once`, `_have_watchman`, watchman-host-fallback, the distrobox-optional path, and the existence-check-before-recreate ceremony.
---

# Exactly one way

Every operation has one path. Multiple paths to the "same" thing diverge over time, hide bugs in the unused branch, and force readers to figure out which is canonical.

## Concrete applications

- **Sync daemon start** — one entrypoint: `sync.sh start [--wait-ready]`. There is no `sync.sh once` and no "synchronous mode" flag. `--wait-ready` covers the "I want to know when it's done seeding" case.
- **Cold copy** — one path: `_cold_copy_via_watchman`. There is no host-watchman fallback, no "detect-and-degrade" branch, no `if not have_watchman: rsync_full`. Watchman missing is a fail-loud SystemExit at the subprocess layer.
- **Dev toolchain habitat** — distrobox, mandatory. There is no `--no-distrobox` flag, no "host-side install" alternative, no `command -v lx ||` host-fallback. The Containerfile is the toolchain spec.
- **Watchman install** — `dnf` inside the container, period. Not "Fedora RPM if available else build from source else apt repo else zip extract". One path.
- **Consent** — running the script is the consent. One press-Enter splash up front. No per-step Y/n.

## The audit prompt

When you see two ways to do something, ask:

1. Is one of them load-bearing for a real platform? (e.g. WSL vs Linux is real; "host has watchman" vs "container has watchman" is not — it's a decision we made.)
2. If both paths exist, what test exercises the non-default branch? If nothing does, delete that branch.
3. Are we maintaining a fallback for an impossible state? (E.g. "what if watchman isn't installed even though sync.Containerfile installs it?" — that's a stale-container problem, fixed by always rebuilding, not by adding a fallback.)

## What this rule does *not* mean

- WSL and Linux paths legitimately differ (engine binary lives in different places, sync only matters on WSL). Real platform branches stay.
- Configurability via `.env` (`BAR_DATA_DIR`, `ALLOW_SPRINGSETTINGS_MOD`) is fine. One mechanism (the env var), one read site, one decision point.

## When tempted to add a second path

Ask: would the user notice if we deleted the new path tomorrow? If no, don't add it. If yes — what's wrong with the existing path that we can't fix in place?
