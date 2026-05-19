---
name: setup-module-registry
description: Every cmd_init step except system-deps lives in scripts/setup/NN-<name>.sh as a self-registering "module" with a uniform read/prompt/write/apply contract. Use this when adding a new setup-time decision, refactoring a `read -rp` that re-asks on re-runs, or wiring a setting into `just doctor`.
---

# Setup module registry

`setup::init` runs at least twice on every fresh machine — once to install distrobox + docker-ce, then a fresh shell to pick up docker group perms, then again to use docker. Anything the first run prompted for and didn't persist gets re-asked on the second run. That's the leak this convention closes.

## The contract

Every setup decision lives in its own file under `scripts/setup/NN-<name>.sh`:

```bash
#!/usr/bin/env bash
# shellcheck source=scripts/setup/_lib.sh
# Module: <name>.

prompt_<name>() {
    # Interactive picker. On success, calls write_env_key <KEY> <value>.
    # No materialization side effects -- writing to .env is the only
    # state mutation here.
}

apply_<name>() {
    # Read the persisted value via read_env_key <KEY> and do the real
    # work. No prompts, no .env writes. Idempotent: must be safe to
    # call repeatedly.
}

register_module <name> <KEY> prompt_<name> apply_<name>
```

`scripts/setup/_lib.sh` is the engine. It exposes:

- `register_module` — validates that `prompt_fn` / `apply_fn` are real defined functions at source time (catches typos before any user sees them) and appends to `SETUP_MODULES`.
- `read_env_key <KEY>` / `write_env_key <KEY> <VAL>` — single source of truth for `.env` I/O. Don't hand-roll grep/sed for `.env`; use these.
- `ensure_module <entry>` — drives one module: read existing value; if empty (or `BAR_RESET_CONFIG=1`), call `prompt_<name>`; then call `apply_<name>`.
- `ensure_module_by_name <name>` — same, looked up by registered name. Used by `just <module>::setup` recipes so they share lifecycle with `cmd_init`.
- `ensure_all_modules` — iterate every module in registration order with auto-numbered `step` headers.
- `doctor_modules` — read-only iteration; prints the registry as a table for `just doctor`.
- `summarize_modules` — read-only iteration for `confirm_setup_plan`'s pre-flight rollup; prints a module's optional `summary_<name>` if defined, else the raw `KEY = value`.

`cmd_init`'s configuration phase becomes a flat sequence of `ensure_module_by_name <name>` calls. There is **no `read -rp` outside a module file** — that's what caused the re-ask leaks before this convention.

## Selection vs action modules

Modules fall into two shapes:

- **Action modules** materialize at config time. `apply_<name>` does the work immediately after the prompt:
  - `chobby_channel`: writes `<data-dir>/chobby_config.json`.
  - `ssh`: runs `scripts/ssh/setup-<choice>-ssh.sh`.
- **Selection modules** record a value that downstream steps in `cmd_init` consume:
  - `features`: persists `BAR_FEATURES`; clone/build/link steps read it via `read_env_key`.
  - `link_on_build`: persists `BAR_LINK_ON_BUILD`; the symlinks step at the end of `cmd_init` reads it.

For selection modules, `apply_<name>() { :; }` (true no-op). The downstream code in `cmd_init` uses `read_env_key BAR_<KEY>` to drive its decision. **Do not duplicate the apply logic between the module and `cmd_init`** — pick one home; selection modules put the home in `cmd_init`'s ordered phases, action modules put the home in `apply_<name>`.

## Deferred apply: `register_module ... deferred`

Some modules' apply touches state that `cmd_init` only creates *later* (clones, builds, the bar-dev distrobox). Running their apply during the front-loaded config phase explodes because that state isn't there yet.

The fifth argument to `register_module` is `when`, defaulting to `config`. Pass `deferred` for modules that need to wait:

```bash
# editor's apply runs distrobox-export, which needs the bar-dev container
# created at cmd_init step 2/N. Tagging deferred so prompt fires at config
# time (front-loaded) but apply waits until apply_deferred_modules is called
# at the end of cmd_init.
register_module editor BAR_EDITOR_SETUP prompt_editor apply_editor deferred
```

`ensure_module` for a deferred module runs only the prompt; `apply_deferred_modules` (called near the end of `cmd_init`, after distrobox/clones/builds) iterates and runs the deferred applies. The user still sees one prompt batch at the top — the apply just shifts in time.

This is bash's stand-in for the `depends-on` graph a real config-management tool would express. Keep deferred to the genuinely-needs-later-state cases; don't tag everything deferred to "be safe".

## Fail loudly inside apply_

`set -e` propagates non-zero through bare commands but **not** through pipes (without `pipefail`), through `2>/dev/null` swallowed errors, or through unchecked loop iterations. Several silent-failure shapes used to hide here:

- **Loops over commands without per-iteration check.** The original `for bin in ...; do distrobox-export "$bin" ...; done` swallowed each export's exit code. Fix: capture exit, accumulate failures, `err`+`return 1` at the end of the loop. Whoever runs `setup::init` finds out *which* binary failed.
- **`cmd | tail -3` style pipes.** `tail` always succeeds; cmd's exit goes nowhere. Fix: `set -eo pipefail` inside the `bash -c`, or `${PIPESTATUS[0]}` checks.
- **`bash -c '<multi-line>'` without `set -e` inside.** The inner script keeps going past failures by default. Fix: first line of the inner script is `set -e`.
- **Bare `echo "$cmd" 2>/dev/null`** that masks all errors. Only acceptable for genuinely-expected failures (probe-and-fall-back); not for installs/exports/configures.

Pattern: every apply_ should either succeed cleanly OR `err`+`return 1`. The user-visible message tells them what failed and how to recover (`Re-run 'just setup::editor'`, `Run 'just setup::distrobox' first`).

`cmd_init` keeps its `ensure_module_by_name <name> || true` wrappers so a single module's apply failure doesn't abort the whole flow — but the module's loud err is what tells the user which module failed and what to do.

## File layout and order

```
scripts/setup/
├── _lib.sh                # engine. Skipped by the loader (underscored).
├── 20-features.sh
├── 25-link-on-build.sh
├── 30-chobby-channel.sh
├── 40-ssh.sh
├── 50-editor.sh
└── 60-springsettings.sh
```

The loader globs `[0-9]*.sh` in alphanumeric order. **Use the numeric prefix as a topological hint**: a module that needs another module's value already in `.env` should come after it. (e.g. `chobby_channel` needs `BAR_DATA_DIR` from earlier; the prefix `30` puts it after the data-dir resolution.) Don't do a runtime topological sort — the prefix IS the convention.

`_load_setup_modules` is called from the **bottom of `setup.sh`**, after every helper the modules call (`checkbox_list`, `info`/`warn`, repo helpers, `read_env_key`) is already defined. Modules can't use forward references.

## Why bash, what intellisense looks like

Setup runs before `python3`, `pipx`, and `distrobox` are guaranteed to exist. A Python rewrite makes orchestration cleaner but introduces a bootstrap problem worse than the orchestration itself. Stay in bash; mitigate the stringly-typed function-pointer cost with discipline:

- `register_module` runs `declare -F "$prompt_fn"` and `declare -F "$apply_fn"` — typos surface at source-load, not at user-prompt time.
- Strict naming: `prompt_<name>`, `apply_<name>`, `read_<name>` / `summary_<name>` (both optional). Grep is the index.
- `# shellcheck source=scripts/setup/_lib.sh` directive at the top of each module file keeps shellcheck cross-file checks working.
- The engine itself (`ensure_module` / `_load_module_entry`) is ~30 lines. Trace it once; the indirection cost is bounded.

## Adding a module

1. Pick a number prefix that places it after any module whose `.env` value yours depends on, before any module that depends on yours.
2. Drop a file at `scripts/setup/NN-<name>.sh` with `prompt_<name>` + `apply_<name>` + `register_module`.
3. Wire it into `cmd_init` with `ensure_module_by_name <name> || true` (the `|| true` lets a module decline gracefully — e.g., `prompt_features` returning 1 if the user picked nothing).
4. (Action module only) — make sure `apply_<name>` is idempotent: re-running on a 2nd `setup::init` invocation must not do destructive work. The pattern is: read current state, compare to desired, no-op if equal.
5. (Selection module only) — wire the downstream consumer to read `BAR_<KEY>` via `read_env_key`, not from a local-variable holdover.
6. Add a recipe `just <module>::setup` whose body is `ensure_module_by_name <name>` if standalone re-prompting is useful (`bar::dev-mode` is the precedent: it calls `apply_chobby_channel` directly because the recipe's whole job is "force the value" without re-prompting).

## What this convention disallows

- `read -rp` anywhere outside `prompt_<name>`. If you're reaching for it, write a module instead.
- Hand-rolled `.env` reads/writes. Use `read_env_key` / `write_env_key`.
- "Skip if .env has the key" guards inside `prompt_<name>`. The engine handles that. (Legacy modules — `prompt_ssh_setup_choice`, `prompt_editor_setup_choice` — still have their own internal guard for back-compat with direct callers; new modules should not.)
- Cross-module reaches in `apply_<name>`. If you need `BAR_DATA_DIR` from inside `apply_chobby_channel`, call `read_env_key BAR_DATA_DIR`. Don't depend on call ordering or shared globals.

## What's special about `cmd_doctor`

`check_doctor_modules` calls `doctor_modules`, which iterates `SETUP_MODULES` and prints `<name> <KEY> <value>`. **Adding a module gets you a doctor row for free** — no separate doctor-side hardcoded list to update. This was the load-bearing reason for picking the registry over the simpler `_module_lifecycle` helper: doctor stays in sync without anyone remembering to update it.

## The escape hatch: `BAR_RESET_CONFIG=1`

`ensure_module` checks `${BAR_RESET_CONFIG:-}` before consulting `.env`. Setting it to anything non-empty forces every module to re-prompt regardless of persisted state. One knob, applied uniformly because every module reads it the same way through the engine. Don't add per-module reset flags.
