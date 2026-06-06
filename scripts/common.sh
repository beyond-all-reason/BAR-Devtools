#!/usr/bin/env bash
# Shared helpers for BAR-Devtools scripts.

: "${DEVTOOLS_DISTROBOX:=bar-dev}"
export DEVTOOLS_DISTROBOX

# WSL-only sister container hosting the sync daemon (scripts/sync.sh).
: "${DEVTOOLS_SYNC_DISTROBOX:=bar-sync}"
export DEVTOOLS_SYNC_DISTROBOX

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'

info()  { echo -e "${BLUE}[info]${NC}  $*" >&2; }
ok()    { echo -e "${GREEN}[ok]${NC}    $*" >&2; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*" >&2; }
err()   { echo -e "${RED}[error]${NC} $*" >&2; }
step()  { echo -e "${CYAN}[step]${NC}  $*" >&2; }

: "${SETUP_ENV_FILE:=$DEVTOOLS_DIR/.env}"

# echo value of key $1 from .env, stripping surrounding quotes
read_env_key() {
    local key="$1"
    [ -f "$SETUP_ENV_FILE" ] || return 0
    local val
    val="$(grep -E "^${key}=" "$SETUP_ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-)"
    val="${val%\"}"; val="${val#\"}"
    printf '%s' "$val"
}

# upsert $1=$2 into .env
write_env_key() {
    local key="$1" val="$2"
    touch "$SETUP_ENV_FILE"
    if grep -q "^${key}=" "$SETUP_ENV_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$SETUP_ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$val" >> "$SETUP_ENV_FILE"
    fi
}

# true if csv list $1 contains tag $2
features_include() {
    local IFS=','
    local f
    for f in $1; do
        [ "$f" = "$2" ] && return 0
    done
    return 1
}

# true if any of $1 (csv) is in the active BAR_FEATURES (read live from .env)
feature_selected() {
    local want="$1" sel f
    sel="$(read_env_key BAR_FEATURES)"
    local IFS=','
    for f in $want; do
        features_include "$sel" "$f" && return 0
    done
    return 1
}

# guard for recipes needing a cloned repo: <feature-csv> <repo-dir> <human-name>
require_repo() {
    local feats="$1" dir="$2" name="$3"
    [ -d "$DEVTOOLS_DIR/$dir" ] && return 0
    if feature_selected "$feats"; then
        err "${name} is selected but not cloned."
        info "Run: just repos::clone ${feats%%,*}"
    else
        err "${name} isn't in your selected features (BAR_FEATURES)."
        info "Add it: just setup::reconfigure  (or clone directly: just repos::clone ${feats%%,*})"
    fi
    return 1
}

is_wsl() {
    [ -n "${WSL_DISTRO_NAME:-}" ] || [ -f /proc/sys/fs/binfmt_misc/WSLInterop ]
}

# returns 0 if $1 >= $2 (dotted numeric versions), else 1
_ver_ge() {
    local IFS=.
    local -a a=($1) b=($2)
    local i max=${#a[@]}
    [ "${#b[@]}" -gt "$max" ] && max=${#b[@]}
    for ((i=0; i<max; i++)); do
        local ai=${a[i]:-0} bi=${b[i]:-0}
        if (( 10#$ai > 10#$bi )); then return 0; fi
        if (( 10#$ai < 10#$bi )); then return 1; fi
    done
    return 0
}

# echo the Docker Compose version podman delegates to; empty if absent or the python provider
_compose_version() {
    podman compose version 2>/dev/null | grep -i 'Docker Compose version' | sed 's/.*version v\?//; s/[^0-9.].*//'
}

# WSL2: nudge toward virtiofs for /mnt/c (faster than Plan 9 drvfs -- the sync
# write path). Key is undocumented + experimental; gated on kernel only, since
# the DeviceHost version isn't visible from Linux. No-op off WSL / on old kernels.
wsl_virtiofs_hint() {
    is_wsl || return 0
    if [ "$(awk '$2=="/mnt/c"{print $3; exit}' /proc/mounts)" = "virtiofs" ]; then
        ok "WSL2 /mnt/c is on virtiofs"
        return 0
    fi
    local kver
    kver="$(uname -r | grep -oE '^[0-9]+(\.[0-9]+)*')"
    _ver_ge "$kver" 6.18.26.3 || return 0
    info "WSL2 kernel $kver supports virtiofs (experimental; faster /mnt/c than Plan 9)."
    info "  Add to %UserProfile%\\.wslconfig, then run 'wsl --shutdown':"
    info "    [wsl2]"
    info "    virtiofs=true"
}

# echo running engine processes that have the local-build binaries open
# (engine::build would corrupt them); game dir from $1 or $BAR_DATA_DIR
_engine_holders() {
    local game_dir="${1:-${BAR_DATA_DIR:-}}"
    [ -n "$game_dir" ] || return 0
    local local_build="$game_dir/engine/local-build"
    [ -e "$local_build" ] || return 0

    local holders=()
    if is_wsl; then
        command -v powershell.exe &>/dev/null || return 0
        local win_local
        win_local="$(wslpath -w "$local_build" 2>/dev/null)" || return 0
        local matches
        matches="$(powershell.exe -NoProfile -NonInteractive -Command "
            Get-CimInstance Win32_Process -Filter \"Name='spring.exe' OR Name='Beyond-All-Reason.exe'\" 2>\$null |
              Where-Object { \$_.ExecutablePath -and \$_.ExecutablePath.StartsWith('$win_local', [StringComparison]::OrdinalIgnoreCase) } |
              Select-Object -ExpandProperty Name
        " 2>/dev/null | tr -d '\r' | sort -u | grep -v '^$' || true)"
        [ -n "$matches" ] && mapfile -t holders <<<"$matches"
    else
        # /proc/PID/exe resolves through symlinks, so compare resolved paths
        local local_real proc pid exe
        local_real="$(readlink -f "$local_build" 2>/dev/null || echo "$local_build")"
        for proc in spring spring-headless; do
            for pid in $(pgrep -x "$proc" 2>/dev/null || true); do
                exe="$(readlink "/proc/$pid/exe" 2>/dev/null)" || continue
                case "$exe" in
                    "$local_real"/*|"$local_build"/*) holders+=("$proc (pid $pid)") ;;
                esac
            done
        done
    fi

    if [ "${#holders[@]}" -gt 0 ]; then
        printf '%s\n' "${holders[@]}"
        return 1
    fi
    return 0
}

# Remove a directory that may contain files owned by a container runtime.
clean_dir() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    rm -rf "$dir" 2>/dev/null || true
    [ -d "$dir" ] || return 0

    local parent; parent="$(dirname "$dir")"
    local name;   name="$(basename "$dir")"

    if command -v podman &>/dev/null; then
        warn "Retrying removal via podman unshare..."
        podman unshare rm -rf "$dir" 2>/dev/null || true
        [ -d "$dir" ] || return 0
    fi

    err "Cannot remove $dir — files owned by another user"
    err "Try: sudo rm -rf '$dir'"
    return 1
}

# true if we're inside a container (spawned by us, or entered interactively)
_in_container() {
    [ -n "${_DEVTOOLS_IN_DISTROBOX:-}" ] || [ -f /run/.containerenv ] || [ -f /.dockerenv ]
}

# refuse to run inside a container; for recipes needing the host podman daemon
require_host() {
    if _in_container; then
        err "This recipe runs on the host (needs podman) -- not from inside bar-dev."
        info "  Exit the container ('exit' or Ctrl-D), then re-run."
        exit 1
    fi
}

# re-exec the calling script inside DEVTOOLS_DISTROBOX (fed via stdin, since
# Just's temp scripts under /run/user aren't visible to the container)
enter_distrobox() {
    if [ -n "${DEVTOOLS_DISTROBOX:-}" ] && ! _in_container; then
        info "Entering distrobox '$DEVTOOLS_DISTROBOX'..."
        exec distrobox enter "$DEVTOOLS_DISTROBOX" -- \
            env _DEVTOOLS_IN_DISTROBOX=1 bash -s -- "$@" < "$0"
    fi
}

# run a single interactive command inside the distrobox with a real PTY.
# script(1) is the PTY wrapper; it parses its arg via /bin/sh, hence printf %q.
distrobox_exec_interactive() {
    if _in_container; then
        exec "$@"
    fi
    if [ -z "${DEVTOOLS_DISTROBOX:-}" ]; then
        err "DEVTOOLS_DISTROBOX not set. Run: just setup::distrobox"
        return 1
    fi
    local quoted_box quoted_cmd="" arg
    quoted_box="$(printf '%q' "$DEVTOOLS_DISTROBOX")"
    for arg in "$@"; do
        quoted_cmd+=" $(printf '%q' "$arg")"
    done
    exec script -qec "distrobox enter ${quoted_box} --${quoted_cmd}" /dev/null
}
