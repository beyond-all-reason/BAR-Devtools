set export

DEVTOOLS_DIR        := justfile_directory()
COMPOSE_FILE        := DEVTOOLS_DIR / "docker-compose.dev.yml"
COMPOSE             := "podman compose -f " + COMPOSE_FILE
BAR_DIR             := DEVTOOLS_DIR / "Beyond-All-Reason"

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

# Switch Chobby to byar-dev so the local .sdd loads (alias for chobby::dev-mode on)
dev-mode:
    @just chobby::dev-mode on

# Build the Windows venv if missing, then regenerate the launcher shim (WSL2-only)
regen-shim:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${REPOS_CONF:=$DEVTOOLS_DIR/repos.conf}"
    : "${REPOS_LOCAL:=$DEVTOOLS_DIR/repos.local.conf}"
    export REPOS_CONF REPOS_LOCAL
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    source "$DEVTOOLS_DIR/scripts/repos.sh"
    if ! is_wsl; then
      err "regen-shim is WSL2-only -- on Linux, 'just bar::launch' runs bar-launch directly."
      exit 1
    fi
    ensure_bar_debug_dir || exit 1
    ensure_bar_launch_venv_windows || exit 1
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
    if [ -z "${BAR_DEBUG_DIR:-}" ]; then
      err "BAR_DEBUG_DIR not set. Run 'just setup::init' on WSL2 first."
      exit 1
    fi
    logfile="$BAR_DEBUG_DIR/.bar-launch/sync.log"
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

# Install BAR's Lua dependencies into .lux/
lux-install: require-bar
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    enter_distrobox
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

    # realpath so podman's ,z relabel follows a symlinked repo instead of the link node.
    compose="podman compose -f $(realpath "$BAR_DIR/tools/headless_testing/docker-compose.yml")"

    # Prefer a local Recoil build over the stock engine download if one exists.
    local_engine="$DEVTOOLS_DIR/RecoilEngine/build-amd64-linux/install"
    if [ -x "$local_engine/spring-headless" ]; then
        local_engine="$(realpath "$local_engine")"
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

# Run bar-mission-kit unit tests (mission DSL recognizer)
mission-kit-test:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    step "Testing bar-mission-kit..."
    bash "$DEVTOOLS_DIR/scripts/mission-kit-cargo.sh" test
    ok "All tests passed"

# Validate mission trigger files (default: hello_pawns)
mission-check *args: require-bar
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    args="{{args}}"
    bash "$DEVTOOLS_DIR/scripts/mission-kit-cargo.sh" run -q -- check ${args:-"$BAR_DIR/modules/missions/hello_pawns"}

# Regenerate the mission AST artifact the in-game editor view renders
mission-ast: require-bar
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    mkdir -p "$BAR_DIR/modules/missions/editor"
    bash "$DEVTOOLS_DIR/scripts/mission-kit-cargo.sh" run -q -- parse "$BAR_DIR/modules/missions/hello_pawns" --out "$BAR_DIR/modules/missions/editor/mission_ast.json"
    ok "Wrote modules/missions/editor/mission_ast.json"

# Run the mission editor service: watch triggers, regen AST, apply UI edits, open-in-editor
mission-serve *args: require-bar
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    bash "$DEVTOOLS_DIR/scripts/mission-kit-cargo.sh" build --release
    args="{{args}}"
    # The editor dir must live in the ENGINE WRITE DIR (the widget reads the
    # artifact and writes intents there via VFS/io; VFS searches it first).
    # Override with BAR_WRITE_DIR if your install writes elsewhere.
    write_dir="${BAR_WRITE_DIR:-$HOME/.local/state/Beyond All Reason}"
    if [ ! -d "$write_dir" ]; then
        write_dir="$BAR_DIR"
        info "engine write dir not found; falling back to the repo"
    fi
    exec "$DEVTOOLS_DIR/bar-mission-kit/target/release/bar-mission-kit" serve \
        ${args:-"$BAR_DIR/modules/missions/hello_pawns"} \
        --editor-dir "$write_dir/modules/missions/editor"

# Tail the game side of the mission editor (bridge, terminal, loader) from infolog
mission-logs:
    #!/usr/bin/env bash
    set -euo pipefail
    write_dir="${BAR_WRITE_DIR:-$HOME/.local/state/Beyond All Reason}"
    exec tail -F "$write_dir/infolog.txt" | grep --line-buffered -Ei 'mission_editor|mission_bridge|mission_loader|mission (armed|reload)'

# Mission-dev session: mission-serve in the background + game launch; serve dies with the session
mission-dev *args: require-bar
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    step "Starting mission-serve..."
    just bar::mission-serve &
    serve_pid=$!
    trap 'kill "$serve_pid" 2>/dev/null || true' EXIT
    just bar::launch {{args}}

# Keep the mission api stack rebased on master and the iteration merge fresh (restack.sh rebase|iterate|test|push|all)
mission-restack *args: require-bar
    @bash "{{DEVTOOLS_DIR}}/scripts/mission-stack/restack.sh" {{args}}
