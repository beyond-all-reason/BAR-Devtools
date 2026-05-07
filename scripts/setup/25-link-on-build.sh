#!/usr/bin/env bash
# shellcheck source=scripts/setup/_lib.sh
# Module: link_on_build.
#
# Whether cmd_init should symlink the cloned repos into the game directory
# after the engine build finishes (Linux native: real symlinks; WSL2:
# registers paths with the sync daemon).
#
# Persisted as BAR_LINK_ON_BUILD=yes|no. Selection-only at config time --
# the actual symlinking happens in cmd_init's "Symlinks" step once the
# repos exist on disk.

prompt_link_on_build() {
    local game_dir
    game_dir="$(detect_game_dir 2>/dev/null)" || true
    if [ -z "$game_dir" ]; then
        info "link_on_build: no game directory detected; will skip symlinking."
        write_env_key BAR_LINK_ON_BUILD "no"
        return 0
    fi
    info "Game directory detected: $game_dir"
    warn "Symlinking will replace any existing engine/chobby/bar dirs there."
    local ans
    read -rp "Symlink all selected components into the game dir after build? [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        write_env_key BAR_LINK_ON_BUILD "yes"
    else
        write_env_key BAR_LINK_ON_BUILD "no"
    fi
}

# Selection-only: actual ln -s / sync-daemon registration runs in cmd_init's
# "Symlinks to game directory" step, which reads BAR_LINK_ON_BUILD.
apply_link_on_build() {
    :
}

register_module link_on_build BAR_LINK_ON_BUILD prompt_link_on_build apply_link_on_build
