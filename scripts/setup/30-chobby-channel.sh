#!/usr/bin/env bash
# shellcheck source=scripts/setup/_lib.sh
# Module: chobby_channel.
#
# Sets Chobby's gameConfig "channel" to "byar-dev" (or "byar"). The choice
# flows downstream in two load-bearing ways:
#
#   1. byar-dev makes Chobby default the skirmish dropdown to the local
#      Beyond-All-Reason.sdd checkout instead of the rapid-fetched test
#      build, so widget/gadget edits actually load.
#   2. Game.gameVersion only contains the literal "$VERSION" placeholder
#      when the local .sdd is loaded; BAR's gadgets.lua:54 uses that
#      substring as the gate for isDevMode. So byar-dev also flips dev-only
#      widgets/warnings on.
#
# We persist the user's choice in BAR_CHOBBY_CHANNEL and apply it on every
# cmd_init / `just bar::dev-mode` / `just bar::launch` run via
# set_chobby_channel -- which has to write BOTH chobby_config.json AND
# IGL_data.lua because Chobby's widget loader otherwise clobbers (1) with the
# previous session's saved value. See scripts/chobby-channel.sh for details.

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

    local ans
    read -rp "Switch Chobby to byar-dev? [Y/n] " ans
    if [ -z "$ans" ] || [[ "$ans" =~ ^[Yy] ]]; then
        write_env_key BAR_CHOBBY_CHANNEL "byar-dev"
    else
        # Record the user's intent (whatever the file currently says).
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

register_module chobby_channel BAR_CHOBBY_CHANNEL prompt_chobby_channel apply_chobby_channel
