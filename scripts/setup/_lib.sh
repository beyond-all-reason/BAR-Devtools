#!/usr/bin/env bash
# Module registry + lifecycle engine for setup::init.
#
# Each "module" is one user-facing setup decision (features, link-on-build,
# chobby channel, ssh, editor, ...). Modules live in scripts/setup/NN-<name>.sh
# and contribute four functions plus one `register_module` call:
#
#   prompt_<name>   interactive picker; on success calls `write_env_key <KEY> <val>`
#   apply_<name>    do the real work using read_env_key's output. No I/O prompts.
#   read_<name>     (optional) wrap read_env_key for module-specific defaults
#   <module file>   ends with: register_module <name> <KEY> prompt_<name> apply_<name>
#
# cmd_init drives the registry through `ensure_module` for each entry in
# SETUP_MODULES order. Each ensure_module reads .env; if the key is set and
# BAR_RESET_CONFIG is not, skip the prompt and go straight to apply.
#
# The same `<name>::setup` recipes can call `ensure_module_by_name <name>` to
# get the same behaviour outside of cmd_init -- one source of truth.
#
# Why bash, not Python: setup::init runs before python3, pipx, and distrobox
# are guaranteed to exist. Bootstrap fragility >> orchestration fragility.
# Stringly-typed function pointers are mitigated by registration-time
# `declare -F` validation (catches typos at source, not run time).

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

# Each entry: "name|env_key|prompt_fn|apply_fn|when|features"
# `when` is "config" (default; apply runs immediately after prompt during
# cmd_init's front-loaded configuration phase) or "deferred" (apply runs
# at the END of cmd_init after distrobox / clones / builds are in place).
# Use deferred for modules whose apply touches state created by later
# cmd_init steps -- the canonical example is editor, whose
# distrobox-export needs the bar-dev container up first.
# `features` is an optional comma-list: the module is only prompted/applied/
# summarized when at least one of those features is selected (empty = always
# relevant). See module_relevant.
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

# Read a module entry by index. Sets SETUP_M_NAME / SETUP_M_KEY /
# SETUP_M_PROMPT / SETUP_M_APPLY / SETUP_M_WHEN / SETUP_M_FEATURES in the
# caller's scope.
_load_module_entry() {
    local entry="$1"
    IFS='|' read -r SETUP_M_NAME SETUP_M_KEY SETUP_M_PROMPT SETUP_M_APPLY SETUP_M_WHEN SETUP_M_FEATURES <<<"$entry"
    : "${SETUP_M_WHEN:=config}"
}

# module_relevant <name> -- true if the module has no feature gate, or if at
# least one of its gate features is in the active selection. cmd_init step 0
# wraps each gated module's ensure_module_by_name in this; summarize_modules
# and apply_deferred_modules skip the modules it rejects. Parses the entry
# into LOCALS so callers iterating the SETUP_M_* globals aren't clobbered.
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

# ---------------------------------------------------------------------------
# .env persistence (read_env_key / write_env_key / SETUP_ENV_FILE) lives in
# scripts/common.sh now -- generic persistence helpers, not registry
# internals, and common.sh is sourced before this file everywhere. The
# registry engine below just calls them.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Lifecycle engine
# ---------------------------------------------------------------------------

# Drive a single module through "read; prompt-if-empty-or-reset; apply".
# The prompt function is responsible for calling write_env_key on its own --
# different modules write different shapes (single value, comma list, etc.)
# and we don't want to assume.
#
# Apply only fires here when when=config. Deferred modules have their
# prompt run at the front-loaded config phase (so the user is asked once
# alongside everything else) but their apply runs later via
# apply_deferred_modules, after cmd_init's system-setup steps complete.
ensure_module() {
    _load_module_entry "$1"
    local current
    current="$(read_env_key "$SETUP_M_KEY")"
    if [ -z "$current" ] || [ -n "${BAR_RESET_CONFIG:-}" ]; then
        "$SETUP_M_PROMPT"
    else
        info "$SETUP_M_NAME: using $SETUP_M_KEY=$current from .env"
        # Point users at the re-prompt path once, on the first skipped module.
        if [ -z "${_RECONFIG_HINT_SHOWN:-}" ]; then
            info "  (re-run 'just setup::reconfigure' to change saved answers)"
            _RECONFIG_HINT_SHOWN=1
        fi
    fi
    if [ "$SETUP_M_WHEN" = "config" ]; then
        "$SETUP_M_APPLY"
    fi
}

# Run apply for every module registered with when=deferred. cmd_init calls
# this once near the end, after distrobox / clones / builds are in place.
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

# Run a single module by name. Used by `just <module>::setup` recipes so
# they share the same lifecycle as cmd_init.
ensure_module_by_name() {
    local name="$1"
    local idx="${SETUP_MODULE_INDEX[$name]:-}"
    if [ -z "$idx" ]; then
        err "ensure_module_by_name: no module registered as '$name'"
        return 1
    fi
    ensure_module "${SETUP_MODULES[$idx]}"
}

# Iterate every registered module through ensure_module. cmd_init's main
# configuration phase becomes a single call to this.
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

# ---------------------------------------------------------------------------
# Doctor: read-only iteration over the registry. Used by `just doctor` and
# the splash at the top of cmd_init to show "what's already configured".
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Pre-flight rollup: one human line per module, for confirm_setup_plan's
# "this is what setup::init will do" summary. A module may define an
# optional `summary_<name>` that echoes a readable description of its
# choice; modules without one fall back to the raw persisted value.
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Source all numbered module files in the same dir. Order = filename order.
# Each module file is responsible for calling register_module at the bottom.
# ---------------------------------------------------------------------------

_load_setup_modules() {
    local dir="${BASH_SOURCE[0]%/*}"
    local f
    # Numbered prefix on each module file gives deterministic order without
    # a topo-sort. Underscored files (like _lib.sh itself) are skipped.
    for f in "$dir"/[0-9]*.sh; do
        [ -f "$f" ] || continue
        # shellcheck disable=SC1090
        source "$f"
    done
}
