#!/usr/bin/env bash
# shellcheck source=scripts/setup/_lib.sh
# Module: chobby_channel.

# shellcheck source=scripts/chobby-channel.sh
source "$DEVTOOLS_DIR/scripts/chobby-channel.sh"

prompt_chobby_channel() {
    local data_dir cfg current
    data_dir="${BAR_DATA_DIR:-$(read_env_key BAR_DATA_DIR)}"
    if [ -z "$data_dir" ]; then
        warn "chobby_channel: BAR_DATA_DIR not set; defaulting to byar-dev (will apply once data dir is configured)."
        write_env_key BAR_CHOBBY_CHANNEL "byar-dev"
        return 0
    fi
    cfg="$data_dir/chobby_config.json"
    current="$(_chobby_game_field "$cfg")"

    info "Chobby's gameConfig channel decides whether your local checkout loads:"
    info "  byar-dev  -> games/Beyond-All-Reason.sdd (your edits, dev mode on)"
    info "  byar      -> latest rapid test build (read-only, dev mode off)"
    [ -n "$current" ] && info "Current chobby_config.json: $current"

    local def=y saved
    saved="$(read_env_key BAR_CHOBBY_CHANNEL)"
    [ -n "$saved" ] && [ "$saved" != "byar-dev" ] && def=n
    if ask_yes_no "Switch Chobby to byar-dev?" "$def"; then
        write_env_key BAR_CHOBBY_CHANNEL "byar-dev"
    else
        write_env_key BAR_CHOBBY_CHANNEL "${current:-byar}"
        warn "Keeping '${current:-byar}' channel. Run 'just bar::dev-mode' to switch later."
    fi
}

apply_chobby_channel() {
    local data_dir desired current widget_current
    data_dir="${BAR_DATA_DIR:-$(read_env_key BAR_DATA_DIR)}"
    [ -n "$data_dir" ] || return 0
    desired="$(read_env_key BAR_CHOBBY_CHANNEL)"
    [ -n "$desired" ] || return 0

    current="$(_chobby_game_field "$data_dir/chobby_config.json")"
    widget_current="$(_chobby_widget_game_field "$data_dir")"
    if [ "$current" = "$desired" ] && { [ -z "$widget_current" ] || [ "$widget_current" = "$desired" ]; }; then
        return 0
    fi
    set_chobby_channel "$data_dir" "$desired"
    ok "Chobby gameConfig set to $desired (chobby_config.json + IGL_data.lua)"
}

register_module chobby_channel BAR_CHOBBY_CHANNEL prompt_chobby_channel apply_chobby_channel config bar,chobby
