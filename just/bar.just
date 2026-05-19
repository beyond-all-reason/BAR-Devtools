set export

DEVTOOLS_DIR        := justfile_directory()
COMPOSE_FILE        := DEVTOOLS_DIR / "docker-compose.dev.yml"
COMPOSE             := "podman compose -f " + COMPOSE_FILE
BAR_DIR             := DEVTOOLS_DIR / "Beyond-All-Reason"
INTEGRATION_COMPOSE := "podman compose -f " + BAR_DIR / "tools" / "headless_testing" / "docker-compose.yml"

[private]
require-bar:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_repo bar Beyond-All-Reason "Beyond All Reason"

[private]
require-emmylua-check:
    #!/usr/bin/env bash
    if ! command -v emmylua_check >/dev/null 2>&1; then
        echo "Error: emmylua_check not on PATH (install in the dev container or from https://github.com/EmmyLuaLs/emmylua-analyzer-rust/releases )." >&2
        exit 1
    fi

# Launch BAR for development (GUI by default; --headless to skip the Tk window)
launch *FLAGS:
    @bash "$DEVTOOLS_DIR/scripts/launch.sh" {{FLAGS}}

# Stop BAR processes and the WSL sync daemon (run before engine::build on WSL)
stop:
    @BAR_LAUNCH_MODE=stop bash "$DEVTOOLS_DIR/scripts/launch.sh"

# Switch Chobby to byar-dev so the local .sdd loads (idempotent)
dev-mode:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    game_dir="${BAR_DATA_DIR:-$(detect_game_dir 2>/dev/null || true)}"
    if [ -z "$game_dir" ]; then
      err "Could not resolve BAR data dir. Set BAR_DATA_DIR or run 'just setup::init' first."
      exit 1
    fi
    write_env_key BAR_CHOBBY_CHANNEL "byar-dev"
    apply_chobby_channel
    ensure_devmode_marker "$game_dir"
    info "Relaunch Chobby (or run 'just bar::launch') to pick up the change."

# Regenerate the Windows-side launcher shim from current .env values (WSL2-only)
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

# Tail the WSL sync daemon log (WSL2-only)
sync-logs *TAIL_FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    if ! grep -qi microsoft /proc/version 2>/dev/null; then
      err "sync-logs is WSL2-only (Linux uses symlinks; nothing to log)."
      exit 1
    fi
    if [ -z "${BAR_DATA_DIR:-}" ]; then
      err "BAR_DATA_DIR not set. Run 'just setup::init' on WSL2 first."
      exit 1
    fi
    logfile="$BAR_DATA_DIR/.bar-launch/sync.log"
    if [ ! -f "$logfile" ]; then
      err "No sync log at $logfile yet -- has 'just bar::launch' or 'sync.sh start' run?"
      exit 1
    fi
    info "Tailing $logfile (Ctrl-C to stop)"
    set -- {{TAIL_FLAGS}}
    [ "${1:-}" = "--" ] && shift
    exec tail -F "$@" "$logfile"

# Tail the engine's infolog from the most recent BAR run
log *TAIL_FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    tail_extra=()
    if is_wsl; then
      if [ -z "${BAR_DATA_DIR:-}" ]; then
        err "BAR_DATA_DIR not set. Run 'just setup::init' on WSL2 first."
        exit 1
      fi
      logfile="$BAR_DATA_DIR/infolog.txt"
      # Plan 9 doesn't forward inotify from Windows writers on /mnt/c; poll instead.
      tail_extra=(---disable-inotify -s 0.5)
    else
      game_dir="$(detect_game_dir 2>/dev/null)" || {
        err "Game directory not detected. Set BAR_DATA_DIR or run 'just setup::init'."
        exit 1
      }
      logfile="$game_dir/infolog.txt"
    fi
    if [ ! -f "$logfile" ]; then
      err "No infolog at $logfile yet -- has the engine run?"
      exit 1
    fi
    info "Tailing $logfile (Ctrl-C to stop)"
    set -- {{TAIL_FLAGS}}
    [ "${1:-}" = "--" ] && shift
    exec tail -F "${tail_extra[@]}" "$@" "$logfile"

# Alias for `bar::log` (just's `alias` directive doesn't work inside modules)
logs *TAIL_FLAGS:
    @just bar::log {{TAIL_FLAGS}}

# Type-check BAR Lua code (EmmyLua analyzer CLI)
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

# Install BAR's Lua dependencies into .lux/ (--clean wipes .lux/ first)
lux-install *args: require-bar
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    enter_distrobox
    for arg in {{args}}; do
        if [ "$arg" = "--clean" ]; then
            warn "Clearing $BAR_DIR/.lux for a fresh install"
            rm -rf "$BAR_DIR/.lux"
        fi
    done
    (cd "$BAR_DIR" && lx --lua-version 5.1 sync)

# Drop into an interactive shell with busted on PATH (for unit-test work)
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

# Drop into an interactive lux shell scoped to BAR's lux.toml (for package work)
lx-shell: require-bar
    #!/usr/bin/env bash
    set -e
    source "$DEVTOOLS_DIR/scripts/common.sh"
    cd "$BAR_DIR"
    ok "Entering lx shell (package work)."
    info "Examples: 'lx add <pkg>', 'lx sync', 'lx install'. Type 'exit' to return."
    echo ""
    distrobox_exec_interactive lx --lua-version 5.1 shell --no-loader

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

    # Prefer a local Recoil build over the stock engine download if one exists.
    compose="{{INTEGRATION_COMPOSE}}"
    local_engine="$DEVTOOLS_DIR/RecoilEngine/build-amd64-linux/install"
    if [ -x "$local_engine/spring-headless" ]; then
        info "Using local engine: $local_engine"
        export BAR_LOCAL_ENGINE="$local_engine"
        export BAR_DEVTOOLS_DIR="$DEVTOOLS_DIR"
        compose="$compose -f $DEVTOOLS_DIR/docker-compose.integrations.local.yml"
    else
        info "Using stock engine (build RecoilEngine with 'just engine::build linux' to use your local build)"
    fi
    $compose up --build --abort-on-container-exit {{args}}

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
