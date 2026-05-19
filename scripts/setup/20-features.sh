#!/usr/bin/env bash
# shellcheck source=scripts/setup/_lib.sh
# Module: features.
#
# Picks which BAR components the contributor will work on. Persisted as
# BAR_FEATURES (comma-separated keys: bar,recoil,teiserver,chobby,...).
# Downstream steps in cmd_init (clone, build, link, ...) read BAR_FEATURES
# via read_env_key to decide what to do.

prompt_features() {
    CHECKBOX_RESULT=""
    # Pre-check the boxes from the saved selection so a reconfigure starts
    # where you left off; first run (no BAR_FEATURES) defaults to everything
    # except spads-source. The `for` order must match the checkbox_list args.
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

# Selection-only module: the downstream clone/build/link steps in cmd_init
# read BAR_FEATURES via read_env_key when they need it. No materialization
# here.
apply_features() {
    :
}

register_module features BAR_FEATURES prompt_features apply_features
