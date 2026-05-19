---
name: trust-the-container
description: Don't probe inside the bar-dev distrobox container for things `dev.Containerfile` is supposed to install. Use this when touching `setup.sh`, `dev.Containerfile`, or distrobox-related plumbing — it explains why we removed several layers of "diligent" if-statements and what to do instead.
---

# Trust the container

`dev.Containerfile` is the single source of truth for what's in `bar-dev`. Once `cmd_setup_distrobox` has built and created the container, every binary listed in the Containerfile is there. Probing for those binaries from setup.sh is unnecessary diligence: it adds friction, drifts from the Containerfile, and makes failures less informative, not more.

## Rules

1. **No `command -v X` checks against the container's contents.** If `dev.Containerfile` says `dnf install watchman`, watchman is in the container. Don't `distrobox enter -- command -v watchman` to confirm. Don't print a `[warn]` if it's missing.
2. **No "stale container, rebuild" self-heal logic.** `setup::init` already calls `cmd_setup_distrobox` unconditionally; that recipe always rebuilds against the current Containerfile. Adding a second rebuild path inside `ensure_*` helpers is duplicate plumbing.
3. **No existence check before `distrobox stop` / `rm`.** Both are idempotent and silent on absence with `--yes` + `>/dev/null 2>&1`. The "already exists, recreating" warn was a UX wart; the fix was to drop the check, not gate it.
4. **Use `/usr/bin/<name>` paths in `distrobox-export`.** When the package manager controls install location, use the path it writes to. Don't `distrobox enter -- command -v <name>` to discover it at runtime.
5. **Let real failures surface.** If watchman isn't on the host PATH at runtime, `subprocess.run(["watchman", ...])` raises `FileNotFoundError` — that's the loud failure we want. Don't add `if not shutil.which("watchman")` guards that print friendlier error messages and then `raise SystemExit`. The friendlier message rots, the underlying failure is plenty clear.

## Pinning RPM/ABI compatibility

The container's base image must match the ABI the toolchain RPMs were built against. Watchman ships `.fc42.x86_64.rpm`; the Containerfile's `FROM` line is `fedora:42`, not `fedora:latest`. **When bumping the watchman version, bump the Fedora pin in lockstep.** This is the one place where being explicit about the Containerfile's environment matters more than convenience.

## Toolchain layout

Everything dev-toolchain — `emmylua_ls`, `clangd`, `stylua`, `lux`, `watchman`, `cargo`, `rust`, `nodejs`, `just`, `gcc` — lives in the container. Host-side we install only what runs at the OS layer: `git`, `docker`, `distrobox`, `python3-watchdog`, `inotify-tools`, `rsync`. If you find yourself adding a new dev tool: it goes in `dev.Containerfile`, exported via `distrobox-export` if it needs to run on the host.

## What the host *does* legitimately probe

- `command -v git`, `command -v docker`, `command -v distrobox` — host installation status. These genuinely may be missing (the deps step installs them).
- `python3 -c 'import watchdog'`, `command -v rsync`, `command -v inotifywait` — these are host-side because `sync.py` runs on the host (it watches `/home/daniel/code` and writes to `/mnt/c`, neither of which the container can see).
- `fs.inotify.max_user_watches` — kernel sysctl, lives on the host.

If you're not sure whether a check is "host probing" or "container probing", look at where the binary needs to be invoked from. Host PATH = host probe = legitimate. Inside `distrobox enter` = stop and reconsider.
