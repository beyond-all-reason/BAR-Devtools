set export

DEVTOOLS_DIR        := justfile_directory()
COMPOSE_FILE        := DEVTOOLS_DIR / "docker-compose.dev.yml"
COMPOSE             := "docker compose -f " + COMPOSE_FILE
BAR_DIR             := DEVTOOLS_DIR / "Beyond-All-Reason"
INTEGRATION_COMPOSE := "docker compose -f " + BAR_DIR / "tools" / "headless_testing" / "docker-compose.yml"
CODEMOD_DIR         := DEVTOOLS_DIR / "bar-lua-codemod"
CODEMOD_BIN         := CODEMOD_DIR / "target" / "release" / "bar-lua-codemod"
# Batch check uses `emmylua_check` (Rust EmmyLua analyzer), baked into the dev
# container image. `emmylua_ls` is LSP-only (no --check) and lives on the host
# for editor integration — see `just setup::editor`.

[private]
require-bar:
    #!/usr/bin/env bash
    if [ ! -d "{{BAR_DIR}}" ]; then
        echo "Error: Beyond-All-Reason is not cloned." >&2
        echo "Run: just repos::clone extra" >&2
        exit 1
    fi

# Type-check BAR Lua code (EmmyLua analyzer CLI — `-c .emmyrc.json` avoids LuaLS-only keys in `.luarc.json`)
check *args: require-bar
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    enter_distrobox
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
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    if [[ "$(uname -m)" == arm64 ]]; then
        echo "Error: integration tests require an x86-64 host." >&2
        echo "The Spring engine used by headless tests has no arm64 build." >&2
        exit 1
    fi

    # If the local Recoil build exists under the devtools workspace
    # (cloned via `just repos::clone extra` + built via `just engine::build
    # linux`), stack an override so the container uses it instead of the
    # stock engine download.
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

# $CREDENTIALS_RUNNER is an opaque command prefix that loads secrets into
# the environment of whatever it wraps. When set, fmt-mig-generate runs
# generate-branches.sh through it so subprocesses (notably the parallel
# `claude --print` workers spawned by scripts/codemod/llm-type-triage.sh) inherit
# the loaded credentials. Without this, the workers would run with the
# credential-less env that just/bash inherits and fail at auth.
#
# Write the prefix however your secrets store wants. Tilde expansion is
# applied. Examples:
#
#   # 1Password CLI
#   CREDENTIALS_RUNNER="op run --env-file=~/code/ai.env.op --"
#
#   # Bitwarden CLI
#   CREDENTIALS_RUNNER="bw run --envfile ~/secrets/ai.env --"
#
#   # direnv loader (treats first arg as a directory whose .envrc to apply)
#   CREDENTIALS_RUNNER="direnv exec ~/code/secrets"
#
#   # raw env injection from a sourceable .env-style file
#   CREDENTIALS_RUNNER="env $(grep -v '^#' ~/.config/anthropic/key.env | xargs)"
#
# When unset, the script runs unwrapped — fine for non-AI invocations
# (e.g. `--push` only) where no subprocess actually needs credentials.

# Regenerate fmt, mig-*, and mig branches from origin/master (uses $CREDENTIALS_RUNNER for AI auth)
fmt-mig-generate *args: require-bar require-codemod require-library
    #!/usr/bin/env bash
    set -euo pipefail
    script="$DEVTOOLS_DIR/scripts/codemod/generate-branches.sh"
    if [[ -n "${CREDENTIALS_RUNNER:-}" ]]; then
        # Expand ~ in the prefix (most secrets-wrapper tools don't expand
        # it themselves when invoked through a non-interactive shell).
        expanded="${CREDENTIALS_RUNNER//\~/$HOME}"
        echo "[info] wrapping fmt-mig-generate with: $expanded" >&2
        # eval re-parses the prefix so multi-token wrappers like
        # `op run --env-file=path --` keep their structure when prepended.
        eval "exec $expanded bash \"\$script\" {{args}}"
    fi
    exec bash "$script" {{args}}

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
