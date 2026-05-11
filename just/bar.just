set export

DEVTOOLS_DIR        := justfile_directory()
COMPOSE_FILE        := DEVTOOLS_DIR / "docker-compose.dev.yml"
COMPOSE             := "podman compose -f " + COMPOSE_FILE
BAR_DIR             := DEVTOOLS_DIR / "Beyond-All-Reason"
INTEGRATION_COMPOSE := "podman compose -f " + BAR_DIR / "tools" / "headless_testing" / "docker-compose.yml"
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

# Stop BAR processes (spring, launcher, bar_launch python) and the WSL
# sync daemon. Idempotent. Run before `just engine::build` to avoid
# Windows file locks on the engine DLLs.
stop:
    @BAR_LAUNCH_MODE=stop bash "$DEVTOOLS_DIR/scripts/launch.sh"

# Switch Chobby's gameConfig channel to `byar-dev`. This makes Chobby's
# skirmish dropdown default to your local `Beyond-All-Reason.sdd` checkout
# (instead of a rapid-downloaded test build), which in turn flips BAR's
# isDevMode on (the gadgets.lua check is "Game.gameVersion contains
# $VERSION", which only the local .sdd has). Persisted in
# <data-dir>/chobby_config.json.
# Switch Chobby to byar-dev so the local .sdd loads (idempotent).
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
    # Lobby-side: chobby's gameConfig channel -> local .sdd is default in skirmish.
    write_env_key BAR_CHOBBY_CHANNEL "byar-dev"
    apply_chobby_channel
    # Engine-side: empty devmode.txt unlocks /cheat, unsigned LuaUI/gadgets,
    # hot-reload, loose VFS. Idempotent (silent if it already exists).
    ensure_devmode_marker "$game_dir"
    info "Relaunch Chobby (or run 'just bar::launch') to pick up the change."

# Regenerate the Windows-side launcher shim from current .env values.
# WSL2-only.
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

# Tail the WSL sync daemon log. WSL2-only.
# Use `just bar::sync-logs -- -n 200` to forward extra tail flags.
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

# Tail the engine's infolog from the most recent BAR run.
# Use `just bar::log -- -n 200` to forward extra tail flags.
#
# WSL2 note: passes `---disable-inotify -s 0.5` so tail stat-polls instead of
# relying on inotify. Plan 9 doesn't forward inotify events from Windows
# writers on /mnt/c, so the default inotify backend would be silent during
# engine writes. Polling at 2Hz is rounding-error vs. engine log volume.
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

# Alias: `bar::logs` (plural). just's `alias` directive doesn't work
# inside modules, so we delegate explicitly.
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
# Assumes .lux/ is already populated; `setup::distrobox` does that for you
# after nuking the cache, and `bar::units` repopulates it as a side effect.
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
