set export

DEVTOOLS_DIR        := justfile_directory()
COMPOSE_FILE        := DEVTOOLS_DIR / "docker-compose.dev.yml"
COMPOSE             := "docker compose -f " + COMPOSE_FILE
BAR_DIR             := DEVTOOLS_DIR / "Beyond-All-Reason"
INTEGRATION_COMPOSE := "docker compose -f " + BAR_DIR / "tools" / "headless_testing" / "docker-compose.yml"
LUALS_VERSION       := "3.17.1"
LUALS_DIR           := DEVTOOLS_DIR / ".devtools" / "lua-language-server"
LUALS_BIN           := LUALS_DIR / "bin" / "lua-language-server"

[private]
require-bar:
    #!/usr/bin/env bash
    if [ ! -d "{{BAR_DIR}}" ]; then
        echo "Error: Beyond-All-Reason is not cloned." >&2
        echo "Run: just repos::clone bar" >&2
        exit 1
    fi

[private]
require-luals:
    #!/usr/bin/env bash
    [ -x "{{LUALS_BIN}}" ] && exit 0
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    step "lua-language-server not found, downloading v{{LUALS_VERSION}}..."
    mkdir -p "{{LUALS_DIR}}"
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)  PLAT="linux-x64" ;;
        aarch64) PLAT="linux-arm64" ;;
        *)       err "Unsupported arch: $ARCH"; exit 1 ;;
    esac
    curl -fsSL "https://github.com/LuaLS/lua-language-server/releases/download/${LUALS_VERSION}/lua-language-server-${LUALS_VERSION}-${PLAT}.tar.gz" \
        | tar xz -C "{{LUALS_DIR}}"
    ok "Downloaded lua-language-server v{{LUALS_VERSION}}"

# Launch BAR for development. GUI by default; pass --headless (or --no-gui)
# plus --play/--source/--boot to run without the Tk window. All flags forward
# verbatim to `bar-launch`; see `just bar::launch --help` for the full set.
launch *FLAGS:
    @bash "$DEVTOOLS_DIR/scripts/launch.sh" {{FLAGS}}

# Stop the Phase 3 sync watcher (Windows-side python.exe). `just bar::launch`
# starts the watcher and leaves it running so subsequent launches are instant
# and game shutdown isn't blocked on watcher teardown -- run this when you
# want to actually free the watcher (e.g. before rebooting WSL2). WSL2-only.
stop:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    if ! grep -qi microsoft /proc/version 2>/dev/null; then
      err "stop is WSL2-only (Linux uses symlinks; no sync daemon to stop)."
      exit 1
    fi
    bash "$DEVTOOLS_DIR/scripts/sync.sh" stop

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

# Tail the Phase 3 sync watcher's log. Pass tail flags after `--`,
# e.g. `just bar::sync-logs -- -f -n 200`. WSL2-only.
sync-logs *TAIL_FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    if ! grep -qi microsoft /proc/version 2>/dev/null; then
      err "sync-logs is WSL2-only (Linux uses symlinks; no sync daemon to log)."
      exit 1
    fi
    exec bash "$DEVTOOLS_DIR/scripts/sync.sh" logs {{TAIL_FLAGS}}

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
    exec tail -F {{TAIL_FLAGS}} "$logfile"

# Type-check BAR Lua code (LuaLS diagnostics)
check *args: require-bar require-luals
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    step "Running LuaLS type check..."
    cd "$BAR_DIR"
    "{{LUALS_BIN}}" --check=. --checklevel=Warning --logpath=/tmp/luals-check {{args}}
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

# Drop into an interactive test shell (busted on PATH)
test-shell: require-bar
    #!/usr/bin/env bash
    set -e
    source "$DEVTOOLS_DIR/scripts/common.sh"
    cd "$BAR_DIR"
    echo -e "${GREEN}[ok]${NC}    Entering lx test shell (busted is available)."
    echo -e "${GREEN}[ok]${NC}    Type 'exit' to return."
    if [ -n "${DEVTOOLS_DISTROBOX:-}" ] && [ -z "${_DEVTOOLS_IN_DISTROBOX:-}" ] && [ ! -f /run/.containerenv ]; then
        exec script -qec "distrobox enter '${DEVTOOLS_DISTROBOX}' -- lx --lua-version 5.1 shell --test --no-loader" /dev/null
    fi
    exec lx --lua-version 5.1 shell --test --no-loader

# Run headless integration tests (x86-64 only)
integrations *args: require-bar
    #!/usr/bin/env bash
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
