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

# Export distrobox binaries for editor integration (emmylua_ls, emmylua_check, clangd, stylua, lx)
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

    for bin in /usr/local/bin/emmylua_ls /usr/local/bin/emmylua_check /usr/bin/clangd /usr/local/bin/stylua /usr/bin/lx; do
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

    # Show current extension state and offer a single action to reconcile.
    # sumneko.lua (LuaLS) conflicts with tangzx.emmylua — two Lua LSPs
    # produce duplicate diagnostics and fighting completions. We remove it
    # as part of the same action that installs the recommended set.
    echo ""
    recommended=(
        "tangzx.emmylua|EmmyLua (Lua language server)"
        "JohnnyMorganz.stylua|StyLua (Lua formatter)"
        "llvm-vs-code-extensions.vscode-clangd|clangd (C/C++ for engine work)"
        "bmalehorn.test-switcher|Test Switcher (Ctrl+Shift+Y to jump between test/source)"
    )
    conflicts=("sumneko.lua")
    have_code=0
    installed=""
    command -v code >/dev/null 2>&1 && have_code=1 && installed="$(code --list-extensions 2>/dev/null || true)"

    state_for() {
        local ext="$1"
        if [ "$have_code" -eq 0 ]; then echo unknown; return; fi
        grep -qixF "$ext" <<<"$installed" && echo installed || echo missing
    }
    render() {
        local ext="$1" label="$2" state="$3"
        case "$state" in
            installed)     printf "  ${CYAN}✓ %-40s${NC} %s  ${DIM}(installed)${NC}\n"        "$ext" "$label" ;;
            just_installed)printf "  ${GREEN}+ %-40s${NC} %s  ${DIM}(just installed)${NC}\n"  "$ext" "$label" ;;
            removed)       printf "  ${YELLOW}− %-40s${NC} %s  ${DIM}(just removed)${NC}\n"  "$ext" "$label" ;;
            conflict)      printf "  ${RED}✗ %-40s${NC} %s  ${DIM}(conflicts — will remove)${NC}\n" "$ext" "$label" ;;
            missing)       printf "  ${RED}✗ %-40s${NC} %s  ${DIM}(missing)${NC}\n"           "$ext" "$label" ;;
            unknown)       printf "  ${DIM}? %-40s${NC} %s\n"                                  "$ext" "$label" ;;
        esac
    }

    declare -A state
    to_install=(); to_remove=()

    info "VS Code / Cursor extensions:"
    for entry in "${recommended[@]}"; do
        ext="${entry%%|*}"; label="${entry#*|}"
        state["$ext"]="$(state_for "$ext")"
        [ "${state[$ext]}" = missing ] && to_install+=("$ext")
        render "$ext" "$label" "${state[$ext]}"
    done
    for ext in "${conflicts[@]}"; do
        if [ "$have_code" -eq 1 ] && grep -qixF "$ext" <<<"$installed"; then
            state["$ext"]=conflict; to_remove+=("$ext")
            render "$ext" "LuaLS — conflicts with EmmyLua (duplicate diagnostics, slower)" "${state[$ext]}"
        fi
    done

    need_action=$(( ${#to_install[@]} + ${#to_remove[@]} ))
    if [ "$have_code" -eq 1 ] && [ "$need_action" -gt 0 ] && [ -t 0 ]; then
        echo ""
        summary=""
        [ ${#to_install[@]} -gt 0 ] && summary="install ${#to_install[@]}"
        [ ${#to_remove[@]} -gt 0 ] && { [ -n "$summary" ] && summary="$summary, "; summary="${summary}remove ${#to_remove[@]}"; }
        read -r -p "Apply changes ($summary)? [y/N] " reply
        if [[ "$reply" =~ ^[Yy]$ ]]; then
            for ext in "${to_install[@]}"; do
                code --install-extension "$ext" --force >/dev/null
                state["$ext"]=just_installed
                info "Installed $ext"
            done
            for ext in "${to_remove[@]}"; do
                code --uninstall-extension "$ext" >/dev/null
                state["$ext"]=removed
                info "Removed $ext"
            done
            echo ""
            info "Updated state:"
            for entry in "${recommended[@]}"; do
                ext="${entry%%|*}"; label="${entry#*|}"
                render "$ext" "$label" "${state[$ext]}"
            done
            for ext in "${conflicts[@]}"; do
                [ -n "${state[$ext]+x}" ] && [ "${state[$ext]}" = removed ] && \
                    render "$ext" "LuaLS" "${state[$ext]}"
            done
        fi
    elif [ "$have_code" -eq 0 ]; then
        info "Install 'code' CLI (Command Palette → 'Shell Command: Install code command in PATH') to manage these automatically."
        info "Cursor users: install tangzx.emmylua from VSIX — marketplace version is outdated."
    fi

    echo ""
    info "Binaries exported to ~/.local/bin:"
    for bin in emmylua_ls emmylua_check clangd stylua lx; do
        if [ -x "$HOME/.local/bin/$bin" ]; then
            printf "  ${CYAN}✓ %s${NC}\n" "$bin"
        else
            printf "  ${RED}✗ %s${NC}  ${DIM}(missing — rerun setup::editor)${NC}\n" "$bin"
        fi
    done
    echo ""

    # BAR's .vscode/ is gitignored, so workspace settings have to be created
    # per-checkout. Write defaults if absent; otherwise diff and leave alone.
    bar_vscode="$DEVTOOLS_DIR/Beyond-All-Reason/.vscode/settings.json"
    bar_vscode_template="$DEVTOOLS_DIR/templates/bar-vscode-settings.json"
    if [ -d "$DEVTOOLS_DIR/Beyond-All-Reason" ]; then
        if [ ! -f "$bar_vscode" ]; then
            mkdir -p "$(dirname "$bar_vscode")"
            cp "$bar_vscode_template" "$bar_vscode"
            ok "Wrote $bar_vscode"
        elif ! diff -q "$bar_vscode_template" "$bar_vscode" >/dev/null 2>&1; then
            warn "$bar_vscode differs from recommended defaults:"
            diff -u "$bar_vscode" "$bar_vscode_template" | sed 's/^/  /' || true
            info "Merge the '[lua]' block (and any missing files.exclude entries) manually if you want format-on-save."
        else
            info "$bar_vscode matches recommended defaults"
        fi
    fi
    echo ""
    ok "Editor integration ready."
    echo ""
    info "If your editor was already open, reload the window (or run"
    info "'EmmyLua: Restart Server' and 'clangd: Restart language server')"
    info "so both extensions pick up the new binaries."

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
