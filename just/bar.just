set export

DEVTOOLS_DIR        := justfile_directory()
COMPOSE_FILE        := DEVTOOLS_DIR / "docker-compose.dev.yml"
COMPOSE             := "docker compose -f " + COMPOSE_FILE
BAR_DIR             := DEVTOOLS_DIR / "Beyond-All-Reason"
INTEGRATION_COMPOSE := "docker compose -f " + BAR_DIR / "tools" / "headless_testing" / "docker-compose.yml"
# Batch check uses `emmylua_check` (Rust EmmyLua analyzer). Install via dev container image or
# https://github.com/EmmyLuaLs/emmylua-analyzer-rust/releases — `emmylua_ls` is LSP-only (no --check).

[private]
require-bar:
    #!/usr/bin/env bash
    if [ ! -d "{{BAR_DIR}}" ]; then
        echo "Error: Beyond-All-Reason is not cloned." >&2
        echo "Run: just repos::clone bar" >&2
        exit 1
    fi

[private]
require-emmylua-check:
    #!/usr/bin/env bash
    if ! command -v emmylua_check >/dev/null 2>&1; then
        echo "Error: emmylua_check not on PATH (install in the dev container or from https://github.com/EmmyLuaLs/emmylua-analyzer-rust/releases )." >&2
        exit 1
    fi

# Launch BAR for development. GUI by default; pass --headless (or --no-gui)
# plus --play/--source/--boot to run without the Tk window. All flags forward
# verbatim to `bar-launch`; see `just bar::launch --help` for the full set.
launch *FLAGS:
    @bash "$DEVTOOLS_DIR/scripts/launch.sh" {{FLAGS}}

# Stop BAR processes started by `just bar::launch` (and any standalone BAR
# launcher / spring.exe still running). Idempotent. Useful before
# `just engine::build` so the rsync that mirrors new DLLs doesn't hit
# Windows file locks. Does NOT stop the WSL sync daemon -- that's
# `bash scripts/sync.sh stop` if you want to.
stop:
    @BAR_LAUNCH_MODE=stop bash "$DEVTOOLS_DIR/scripts/launch.sh"

# Regenerate the Windows-side launcher shim ($BAR_DEVSYNC_DIR/bin/bar-launch.cmd)
# from the current BAR_DEVSYNC_DIR / venv-python paths. Use this after editing
# .env values that the shim has baked in as literals. WSL2-only.
regen-shim:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    if ! is_wsl; then
      err "regen-shim is WSL2-only -- on Linux, 'just bar::launch' runs bar-launch directly."
      exit 1
    fi
    regenerate_bar_launch_cmd_shim

# Tail the WSL sync daemon log (cold-copy + watcher). Follows by default.
# Pass tail flags after `--`, e.g. `just bar::sync-logs -- -n 200`. WSL2-only.
sync-logs *TAIL_FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    if ! grep -qi microsoft /proc/version 2>/dev/null; then
      err "sync-logs is WSL2-only (Linux uses symlinks; nothing to log)."
      exit 1
    fi
    if [ -z "${BAR_DEVSYNC_DIR:-}" ]; then
      err "BAR_DEVSYNC_DIR not set. Run 'just setup::init' on WSL2 first."
      exit 1
    fi
    logfile="$BAR_DEVSYNC_DIR/.bar-launch/sync.log"
    if [ ! -f "$logfile" ]; then
      err "No sync log at $logfile yet -- has 'just bar::launch' or 'sync.sh start' run?"
      exit 1
    fi
    info "Tailing $logfile (Ctrl-C to stop)"
    # `just bar::sync-logs -- -n 200` forwards the `--` into TAIL_FLAGS; drop it
    # so tail doesn't read `-n`/`200` as filenames after the option terminator.
    set -- {{TAIL_FLAGS}}
    [ "${1:-}" = "--" ] && shift
    exec tail -F "$@" "$logfile"

# Tail the engine's infolog from the most recent BAR run. The engine writes
# this itself -- we don't capture launch.sh output, since `bar-launch` exits
# right after spawning the engine and stdout/stderr already inherit the user's
# terminal. Use `just bar::log -- -n 200` to pass extra `tail` flags.
log *TAIL_FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    game_dir="$(detect_game_dir 2>/dev/null)" || {
      err "Game directory not detected. Set BAR_GAME_DIR or run 'just setup::init'."
      exit 1
    }
    logfile="$game_dir/infolog.txt"
    if [ ! -f "$logfile" ]; then
      err "No infolog at $logfile yet -- has the engine run from this data dir?"
      exit 1
    fi
    info "Tailing $logfile (Ctrl-C to stop)"
    # `just bar::log -- -n 200` forwards the `--` into TAIL_FLAGS; drop it
    # so tail doesn't read `-n`/`200` as filenames after the option terminator.
    set -- {{TAIL_FLAGS}}
    [ "${1:-}" = "--" ] && shift
    exec tail -F "$@" "$logfile"

# Alias: `just bar::logs` (plural) does the same thing as `bar::log`.
# Both `log` and `logs` are common muscle memory; recipe aliases would be
# cleaner but `just`'s `alias` directive only works at the root justfile,
# not inside modules, so we delegate explicitly.
logs *TAIL_FLAGS:
    @just bar::log {{TAIL_FLAGS}}

# Type-check BAR Lua code (EmmyLua analyzer CLI — `-c .emmyrc.json` avoids LuaLS-only keys in `.luarc.json`)
check *args: require-bar require-emmylua-check
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    step "Running emmylua_check (EmmyLua analyzer)..."
    cd "$BAR_DIR"
    emmylua_check -c .emmyrc.json . {{args}}
    ok "Type check complete"

# Lint BAR Lua code (luacheck via lux)
lint *args: require-bar
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    enter_distrobox
    (cd "$BAR_DIR" && lx --lua-version 5.1 lint {{args}})

# Format BAR Lua code (stylua via lux)
fmt *args: require-bar
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    enter_distrobox
    (cd "$BAR_DIR" && lx --lua-version 5.1 exec stylua . {{args}})

# Run busted unit tests
units *args: require-bar
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    enter_distrobox
    (cd "$BAR_DIR" && lx --lua-version 5.1 test {{args}})

# Drop into an interactive shell with busted on PATH (for unit-test work).
# Named units-shell, not test-shell, because `bar::test` runs both units AND
# integrations -- this REPL is specifically the unit-test environment.
units-shell: require-bar
    #!/usr/bin/env bash
    set -e
    source "$DEVTOOLS_DIR/scripts/common.sh"
    cd "$BAR_DIR"
    ok "Entering lx test shell (busted on PATH)."
    echo ""
    info "Filter to specific tests by tagging their description with #<tag>"
    info "and running busted with -t <tag>. Example:"
    echo ""
    echo -e "  ${DIM}-- in some_spec.lua${NC}"
    echo -e "  ${CYAN}it(\"computes attack range #focus\", function() ... end)${NC}"
    echo ""
    echo -e "  ${DIM}# in this shell${NC}"
    echo -e "  ${CYAN}busted -t focus${NC}"
    echo ""
    info "Type 'exit' to return."
    echo ""
    distrobox_exec_interactive lx --lua-version 5.1 shell --test --no-loader

# Run headless integration tests (x86-64 only)
integrations *args: require-bar
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_host
    if [[ "$(uname -m)" == arm64 ]]; then
        echo "Error: integration tests require an x86-64 host." >&2
        echo "The Spring engine used by headless tests has no arm64 build." >&2
        exit 1
    fi
    {{INTEGRATION_COMPOSE}} up --build --abort-on-container-exit {{args}}

# Run all BAR tests (unit + integrations)
test: units integrations

# Install git pre-commit hook in the BAR repo
setup-hooks:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    hook="$BAR_DIR/.git/hooks/pre-commit"
    if [ ! -d "$BAR_DIR/.git" ]; then
        err "BAR repo not found at $BAR_DIR"
        info "Clone it first: just repos::clone bar"
        exit 1
    fi
    mkdir -p "$(dirname "$hook")"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -e' \
        'echo "[pre-commit] Running stylua..."' \
        'lx --lua-version 5.1 exec stylua .' \
        > "$hook"
    chmod +x "$hook"
    ok "Installed pre-commit hook at $hook"
    if [ -f "$BAR_DIR/.git-blame-ignore-revs" ]; then
        git -C "$BAR_DIR" config blame.ignoreRevsFile .git-blame-ignore-revs
        ok "Configured git blame to ignore formatting commits"
    fi
