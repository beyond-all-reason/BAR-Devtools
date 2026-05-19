# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

BAR-Devtools is an **orchestrator**, not an application. It clones several sibling repositories (`Beyond-All-Reason`, `RecoilEngine`, `teiserver`, `bar-lobby`, `BYAR-Chobby`, `spads_config_bar`, `lua-doc-extractor`) into this directory (gitignored) and provides `just` recipes that operate across them. Most "BAR-Devtools" work is touching scripts that drive the cloned repos, not editing the cloned repos themselves.

Many recipes assume the bar-dev distrobox container exists. `dev.Containerfile` is the canonical manifest of dev-tool dependencies — Lua 5.1, lx (lumen-oss/lux), Node, Cargo, clangd, StyLua, EmmyLua. Recipes that need those tools call `enter_distrobox` from `scripts/common.sh` to re-exec inside the container.

## Common commands

```bash
just doctor                 # read-only env audit (run this first when debugging)
just --list                 # all top-level modules
just <module>::              # list a module's recipes

just setup::init            # one-time full setup (front-loads all prompts, then unattended)
just setup::distrobox       # rebuild just the bar-dev container
just setup::editor          # re-wire VS Code / Cursor language servers

just bar::fmt               # stylua across BAR
just bar::lint              # luacheck via lx
just bar::units             # busted unit tests via lx
just bar::units-shell       # interactive busted shell (--test + --no-loader)
just bar::lx-shell          # general lx shell for `lx add`, `lx sync`, etc.

just tei::test [path]       # teiserver mix tests (single file by path)
just tei::setup-test-db     # re-run after pulling teiserver migrations

just engine::build linux    # RecoilEngine via docker-build-v2
just link::create engine    # symlink into game data dir

just services::up [svc...]  # postgres + teiserver (+ optional spads, lobby)
just services::logs <svc>   # tail container logs
just services::reset        # nuke volumes and restart (destructive)

just repos::clone [repo]    # clone or sync per repos.conf / repos.local.conf
```

## Architecture (non-obvious parts)

### just module layout

`Justfile` declares modules; each `just/<mod>.just` is a self-contained recipe set. Recipes share helpers via `scripts/common.sh` (sourced at the top of each multi-line recipe body). `enter_distrobox` is the key boundary helper — recipes that need lx / busted / stylua / emmylua call it to re-exec inside `bar-dev`.

### setup is split

- **`scripts/setup.sh`** is monolithic and runs in a fixed order (deps → docker → distrobox → repos → engine → editor → ...). Top-level orchestration only.
- **`scripts/setup/NN-<name>.sh`** are self-registering modules with a uniform read/prompt/write/apply contract. Setup-time *decisions* live here, not in `setup.sh`. Adding a new prompt? It belongs in a new module file under `scripts/setup/`. See `.claude/skills/setup-module-registry/`.

### Two distroboxes

- `bar-dev` — built from `docker/dev.Containerfile`. The dev toolchain. Every contributor has it.
- `bar-sync` — built from `docker/sync.Containerfile`. **WSL-only.** Hosts the `wsl-watchdog-mntc` sync daemon (`scripts/sync.py`, `scripts/sync.sh`). Linux-native contributors never run this — don't bundle its deps into `dev.Containerfile`.

### `repos.conf` + `repos.local.conf`

`repos.conf` is the upstream default. `repos.local.conf` (gitignored) overrides per-repo URL/branch and can replace a clone with a symlink via a 5th column. `scripts/repos.sh` parses both and feeds `just repos::clone`.

### Service stack

`docker-compose.dev.yml` defines postgres + teiserver + (optional) spads + (optional) bar-lobby. `bar-lobby` runs natively, not in Docker, despite being in the compose file as a convenience target. Teiserver's first boot seeds the DB and creates a `spadsbot` account; this is handled by `docker/teiserver-entrypoint.sh`.

## Rules encoded as skills

`.claude/skills/` contains five skill files. They are the project's design rules — read the relevant one before changing the area it covers, even if a different approach seems obvious:

- **exactly-one-way** — every operation has one path; no `_have_X` fallbacks, no "if X exists else Y" ceremony around things `setup::*` already establishes. Touched when reviewing/refactoring setup or sync.
- **front-load-prompts** — every interactive decision in a long-running recipe is asked in the Step 0 batch up front, never mid-run. Touched when adding interactive decisions to `cmd_init` or any multi-minute recipe.
- **setup-module-registry** — adding a setup-time decision → new file under `scripts/setup/NN-<name>.sh` using the read/prompt/write/apply contract.
- **trust-the-container** — don't probe inside `bar-dev` for binaries that `dev.Containerfile` installs. Touched when editing `setup.sh`, `dev.Containerfile`, or distrobox-related plumbing.
- **wsl2-sync-architecture** — hard-won facts about the WSL2 ↔ Windows boundary, including when to re-probe the sync architecture and what a probe must measure. Read before changing `sync.py`, `sync.sh`, `launch.sh`, or watchman/rsync invocations.

## Cross-repo conventions

- **lx version pin.** `docker/dev.Containerfile` (`LUX_VERSION`) and the BAR repo's `.github/workflows/test_unit.yml` must move in lockstep. Lockfile integrity checks differ between minor versions; skew makes locally regenerated `lux.lock` files fail CI (and vice versa).
- **Editor wrappers in `~/.local/bin`.** `setup::editor` exports `lx`, `stylua`, `emmylua_ls`, `emmylua_check`, `clangd` from the container via `distrobox-export`. Host-side editors (VS Code, Cursor) find these on PATH. Do not check for them inside the container — the wrappers are a host-side concern.
- **`.env` is the persistence layer.** Justfile uses `set dotenv-load`. Setup modules write decisions there (`BAR_DATA_DIR`, `DEVTOOLS_DISTROBOX`, feature flags). Don't read user state from any other location.
