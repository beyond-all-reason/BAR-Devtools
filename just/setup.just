set export

DEVTOOLS_DIR := justfile_directory()
COMPOSE_FILE := DEVTOOLS_DIR / "docker-compose.dev.yml"
COMPOSE      := "docker compose -f " + COMPOSE_FILE
REPOS_CONF   := DEVTOOLS_DIR / "repos.conf"
REPOS_LOCAL  := DEVTOOLS_DIR / "repos.local.conf"

# Full first-time setup: install deps, clone repos, build images
init *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/repos.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    cmd_init {{args}}

# Install system packages (git, podman/docker, distrobox)
deps:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    cmd_install_deps

# Build dev container image and create distrobox
distrobox:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    cmd_setup_distrobox

# Export distrobox binaries for editor integration (clangd, emmylua_ls, stylua)
editor:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    if [ -z "${DEVTOOLS_DISTROBOX:-}" ]; then
        err "DEVTOOLS_DISTROBOX not set. Run: just setup::distrobox"
        exit 1
    fi
    local_bin="$HOME/.local/bin"
    mkdir -p "$local_bin"
    for bin in /usr/local/bin/emmylua_ls /usr/bin/clangd /usr/local/bin/stylua; do
        name="$(basename "$bin")"
        info "Exporting $name..."
        distrobox enter "$DEVTOOLS_DISTROBOX" -- distrobox-export --bin "$bin" --export-path "$local_bin"
    done
    echo ""
    if [ -f "$DEVTOOLS_DIR/RecoilEngine/CMakeLists.txt" ]; then
        step "Generating compile_commands.json for clangd..."
        distrobox enter "$DEVTOOLS_DISTROBOX" -- bash -c "
            cd '$DEVTOOLS_DIR/RecoilEngine' \
            && mkdir -p build \
            && cd build \
            && cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON .. 2>&1 | tail -3
        "
        ln -sf build/compile_commands.json "$DEVTOOLS_DIR/RecoilEngine/compile_commands.json"
        ok "compile_commands.json ready"
    else
        info "RecoilEngine not cloned — skipping compile_commands.json"
    fi
    echo ""
    ok "Editor integration ready."
    echo ""
    info "Install these VS Code / Cursor extensions:"
    echo "  - EmmyLua (tangzx.emmylua) — Cursor users: install from VSIX, marketplace version is outdated"
    echo "    https://marketplace.visualstudio.com/items?itemName=tangzx.emmylua"
    echo "  - StyLua (JohnnyMorganz.stylua)"
    echo "  - clangd (llvm-vs-code-extensions.vscode-clangd) — for engine C++ work"
    echo ""
    info "Add to your editor settings (JSON):"
    echo '  "emmylua.ls.executablePath": "~/.local/bin/emmylua_ls",'
    echo '  "[lua]": { "editor.defaultFormatter": "JohnnyMorganz.stylua", "editor.formatOnSave": true }'

# Install git pre-commit hooks (stylua + luacheck) in BAR repo
hooks:
    just bar::setup-hooks

# Check prerequisites and build Docker images
check:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/repos.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    cmd_setup
