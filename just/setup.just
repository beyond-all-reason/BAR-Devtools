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

# Export distrobox binaries for editor integration (clangd, emmylua_check, stylua)
# emmylua_ls is downloaded directly to the host instead of exported, because
# distrobox-enter / rootless podman don't reliably forward SIGTERM to the
# in-container LSP — VSCode then escalates to SIGKILL on shutdown and the
# extension reports "Server process exited with signal SIGKILL".
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

    # Export CLI tools from the distrobox (one-shot invocations, no signaling concerns)
    for bin in /usr/local/bin/emmylua_check /usr/bin/clangd /usr/local/bin/stylua; do
        name="$(basename "$bin")"
        info "Exporting $name..."
        distrobox enter "$DEVTOOLS_DISTROBOX" -- distrobox-export --bin "$bin" --export-path "$local_bin"
    done

    # Download emmylua_ls directly to the host, pinned to the same version
    # baked into dev.Containerfile so the LSP and the project tooling stay in sync.
    emmylua_version="$(grep -oP '(?<=^ARG EMMYLUA_VERSION=).*' "$DEVTOOLS_DIR/docker/dev.Containerfile")"
    case "$(uname -m)" in
        x86_64)  ls_asset="emmylua_ls-linux-x64.tar.gz" ;;
        aarch64) ls_asset="emmylua_ls-linux-arm64-glibc.2.17.tar.gz" ;;
        *) err "unsupported arch for emmylua_ls: $(uname -m)"; exit 1 ;;
    esac
    info "Downloading emmylua_ls $emmylua_version to $local_bin..."
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL "https://github.com/EmmyLuaLs/emmylua-analyzer-rust/releases/download/${emmylua_version}/${ls_asset}" \
        | tar xz -C "$tmp"
    install -m 0755 "$tmp/emmylua_ls" "$local_bin/emmylua_ls"
    ok "emmylua_ls $("$local_bin/emmylua_ls" --version | awk '{print $2}') installed"
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
