#!/usr/bin/env bash
# shellcheck source=scripts/setup/_lib.sh
# Module: link_on_build.

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
    local def=n
    [ "$(read_env_key BAR_LINK_ON_BUILD)" = "yes" ] && def=y
    if ask_yes_no "Symlink all selected components into the game dir after build?" "$def"; then
        write_env_key BAR_LINK_ON_BUILD "yes"
    else
        write_env_key BAR_LINK_ON_BUILD "no"
    fi
}

apply_link_on_build() {
    :
}

summary_link_on_build() {
    if [ "$(read_env_key BAR_LINK_ON_BUILD)" = "yes" ]; then
        echo "symlink selected repos into the game directory after build"
    else
        echo "no game-directory symlinks"
    fi
}

register_module link_on_build BAR_LINK_ON_BUILD prompt_link_on_build apply_link_on_build config bar,recoil,chobby
