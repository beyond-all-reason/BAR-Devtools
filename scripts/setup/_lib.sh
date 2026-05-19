#!/usr/bin/env bash
# Module registry + lifecycle engine for setup::init.

# Each entry: "name|env_key|prompt_fn|apply_fn|when|features"
# when=config applies right after the prompt; when=deferred defers apply to
# the end of cmd_init (after distrobox/clones/builds exist).
declare -ag SETUP_MODULES=()
declare -Ag SETUP_MODULE_INDEX=()  # name -> index in SETUP_MODULES

register_module() {
    local name="$1" key="$2" prompt_fn="$3" apply_fn="$4" when="${5:-config}" features="${6:-}"
    local f
    for f in "$prompt_fn" "$apply_fn"; do
        if ! declare -F "$f" >/dev/null; then
            echo "[register_module] $name: function '$f' not defined" >&2
            return 1
        fi
    done
    case "$when" in
        config|deferred) ;;
        *) echo "[register_module] $name: unknown when='$when' (config|deferred)" >&2; return 1 ;;
    esac
    SETUP_MODULE_INDEX["$name"]=${#SETUP_MODULES[@]}
    SETUP_MODULES+=("$name|$key|$prompt_fn|$apply_fn|$when|$features")
}

# parse an entry into the SETUP_M_* vars in the caller's scope
_load_module_entry() {
    local entry="$1"
    IFS='|' read -r SETUP_M_NAME SETUP_M_KEY SETUP_M_PROMPT SETUP_M_APPLY SETUP_M_WHEN SETUP_M_FEATURES <<<"$entry"
    : "${SETUP_M_WHEN:=config}"
}

# true if $1 has no feature gate or one of its gate features is selected.
# parses into locals so callers iterating SETUP_M_* aren't clobbered.
module_relevant() {
    local idx="${SETUP_MODULE_INDEX[$1]:-}"
    if [ -z "$idx" ]; then
        err "module_relevant: no module registered as '$1'"
        return 1
    fi
    local _n _k _p _a _w _feats
    IFS='|' read -r _n _k _p _a _w _feats <<<"${SETUP_MODULES[$idx]}"
    [ -z "$_feats" ] && return 0
    feature_selected "$_feats"
}

# drive a module through "read; prompt if empty or reset; apply".
# apply only fires here for when=config; deferred modules apply later.
ensure_module() {
    _load_module_entry "$1"
    local current
    current="$(read_env_key "$SETUP_M_KEY")"
    if [ -z "$current" ] || [ -n "${BAR_RESET_CONFIG:-}" ]; then
        "$SETUP_M_PROMPT"
    else
        info "$SETUP_M_NAME: using $SETUP_M_KEY=$current from .env"
        if [ -z "${_RECONFIG_HINT_SHOWN:-}" ]; then
            info "  (re-run 'just setup::reconfigure' to change saved answers)"
            _RECONFIG_HINT_SHOWN=1
        fi
    fi
    if [ "$SETUP_M_WHEN" = "config" ]; then
        "$SETUP_M_APPLY"
    fi
}

# run apply for every when=deferred module
apply_deferred_modules() {
    local entry
    for entry in "${SETUP_MODULES[@]}"; do
        _load_module_entry "$entry"
        [ "$SETUP_M_WHEN" = "deferred" ] || continue
        module_relevant "$SETUP_M_NAME" || continue
        step "deferred apply: $SETUP_M_NAME"
        "$SETUP_M_APPLY"
    done
}

# run a single module by name; used by `just <module>::setup` recipes
ensure_module_by_name() {
    local name="$1"
    local idx="${SETUP_MODULE_INDEX[$name]:-}"
    if [ -z "$idx" ]; then
        err "ensure_module_by_name: no module registered as '$name'"
        return 1
    fi
    ensure_module "${SETUP_MODULES[$idx]}"
}

# iterate every registered module through ensure_module
ensure_all_modules() {
    local n=${#SETUP_MODULES[@]} i=0 entry
    for entry in "${SETUP_MODULES[@]}"; do
        i=$((i+1))
        _load_module_entry "$entry"
        step "config $i/$n  $SETUP_M_NAME"
        ensure_module "$entry"
        echo ""
    done
}

doctor_modules() {
    local entry val
    printf "  %-20s %-22s %s\n" "MODULE" "KEY" "VALUE"
    printf "  %-20s %-22s %s\n" "------" "---" "-----"
    for entry in "${SETUP_MODULES[@]}"; do
        _load_module_entry "$entry"
        val="$(read_env_key "$SETUP_M_KEY")"
        if [ -n "$val" ]; then
            printf "  %-20s %-22s %s\n" "$SETUP_M_NAME" "$SETUP_M_KEY" "$val"
        else
            printf "  %-20s %-22s ${DIM}<unset>${NC}\n" "$SETUP_M_NAME" "$SETUP_M_KEY"
        fi
    done
}

# one human line per module for confirm_setup_plan; a module may define an
# optional summary_<name>, else the raw persisted value is shown
summarize_modules() {
    local entry fn val
    for entry in "${SETUP_MODULES[@]}"; do
        _load_module_entry "$entry"
        module_relevant "$SETUP_M_NAME" || continue
        fn="summary_${SETUP_M_NAME}"
        if declare -F "$fn" >/dev/null; then
            val="$("$fn")"
        else
            val="$(read_env_key "$SETUP_M_KEY")"
            val="${val:-<unset>}"
        fi
        printf '    %-16s %s\n' "$SETUP_M_NAME" "$val"
    done
}

# source numbered module files in filename order (underscored files skipped)
_load_setup_modules() {
    local dir="${BASH_SOURCE[0]%/*}"
    local f
    for f in "$dir"/[0-9]*.sh; do
        [ -f "$f" ] || continue
        # shellcheck disable=SC1090
        source "$f"
    done
}
