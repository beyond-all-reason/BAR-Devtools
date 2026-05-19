#!/usr/bin/env bash
# shellcheck source=scripts/setup/_lib.sh
# Module: features.

prompt_features() {
    CHECKBOX_RESULT=""
    # `for` order must match the checkbox_list args below
    local cur f init=()
    cur="$(read_env_key BAR_FEATURES)"
    for f in bar recoil teiserver chobby spads-source; do
        if [ -n "$cur" ]; then
            features_include "$cur" "$f" && init+=(1) || init+=(0)
        elif [ "$f" = "spads-source" ]; then
            init+=(0)
        else
            init+=(1)
        fi
    done
    if ! checkbox_list "Which BAR components will you work on?" \
        "bar|BAR game content + bar-lobby client|${init[0]}" \
        "recoil|Recoil engine (build from source)|${init[1]}" \
        "teiserver|Teiserver (lobby/matchmaking server)|${init[2]}" \
        "chobby|Chobby (in-game lobby)|${init[3]}" \
        "spads-source|SPADS source (autohost dev, optional)|${init[4]}"
    then
        warn "Selection cancelled."
        return 1
    fi
    if [ -z "$CHECKBOX_RESULT" ]; then
        warn "No features selected. Nothing to clone or build."
        return 1
    fi
    write_env_key BAR_FEATURES "$CHECKBOX_RESULT"
    ok "Selected: $CHECKBOX_RESULT"
}

apply_features() {
    :
}

register_module features BAR_FEATURES prompt_features apply_features
