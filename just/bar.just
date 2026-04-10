set export

DEVTOOLS_DIR        := justfile_directory()
COMPOSE_FILE        := DEVTOOLS_DIR / "docker-compose.dev.yml"
COMPOSE             := "docker compose -f " + COMPOSE_FILE
BAR_DIR             := DEVTOOLS_DIR / "Beyond-All-Reason"
INTEGRATION_COMPOSE := "docker compose -f " + BAR_DIR / "tools" / "headless_testing" / "docker-compose.yml"
CODEMOD_DIR         := DEVTOOLS_DIR / "bar-lua-codemod"
CODEMOD_BIN         := CODEMOD_DIR / "target" / "release" / "bar-lua-codemod"
# Batch check uses `emmylua_check` (Rust EmmyLua analyzer). Install via dev container image or
# https://github.com/EmmyLuaLs/emmylua-analyzer-rust/releases — `emmylua_ls` is LSP-only (no --check).

[private]
require-bar:
    #!/usr/bin/env bash
    if [ ! -d "{{BAR_DIR}}" ]; then
        echo "Error: Beyond-All-Reason is not cloned." >&2
        echo "Run: just repos::clone extra" >&2
        exit 1
    fi

[private]
require-emmylua-check:
    #!/usr/bin/env bash
    if ! command -v emmylua_check >/dev/null 2>&1; then
        echo "Error: emmylua_check not on PATH (install in the dev container or from https://github.com/EmmyLuaLs/emmylua-analyzer-rust/releases )." >&2
        exit 1
    fi

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

# Build bar-lua-codemod binary
codemod-build:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    step "Building bar-lua-codemod..."
    bash "$DEVTOOLS_DIR/scripts/codemod-cargo.sh" build --release
    ok "Built: {{CODEMOD_BIN}}"

# Run bar-lua-codemod unit tests
codemod-test:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    step "Testing bar-lua-codemod..."
    bash "$DEVTOOLS_DIR/scripts/codemod-cargo.sh" test
    ok "All tests passed"

[private]
require-codemod:
    #!/usr/bin/env bash
    [ -x "{{CODEMOD_BIN}}" ] && exit 0
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    step "bar-lua-codemod not found, building..."
    bash "$DEVTOOLS_DIR/scripts/codemod-cargo.sh" build --release
    ok "Built bar-lua-codemod"

# Run codemod transforms + stylua (contributors run after rebasing)
fmt-mig: require-bar require-codemod
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    enter_distrobox
    step "bracket-to-dot transform..."
    "{{CODEMOD_BIN}}" bracket-to-dot --path "$BAR_DIR" --exclude common/luaUtilities
    step "rename-aliases transform..."
    "{{CODEMOD_BIN}}" rename-aliases --path "$BAR_DIR" --exclude common/luaUtilities
    step "detach-bar-modules transform..."
    "{{CODEMOD_BIN}}" detach-bar-modules --path "$BAR_DIR" --exclude common/luaUtilities
    step "spring-split transform..."
    "{{CODEMOD_BIN}}" spring-split --path "$BAR_DIR" --library "$BAR_DIR/recoil-lua-library/src" --exclude common/luaUtilities
    step "stylua..."
    (cd "$BAR_DIR" && lx --lua-version 5.1 exec stylua .)
    ok "fmt-mig complete"

[private]
require-library:
    just lua::library
    just lua::link

# Regenerate fmt, mig-*, and mig branches from origin/master
fmt-mig-generate *args: require-bar require-codemod require-library
    bash "$DEVTOOLS_DIR/scripts/generate-branches.sh" {{args}}

# Install git pre-commit hook in the BAR repo
setup-hooks:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    hook="$BAR_DIR/.git/hooks/pre-commit"
    if [ ! -d "$BAR_DIR/.git" ]; then
        err "BAR repo not found at $BAR_DIR"
        info "Clone it first: just repos::clone extra"
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
