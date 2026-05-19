#!/usr/bin/env bash
# Shared helpers for BAR-Devtools scripts.
# Source this file; it only defines functions and variables.

# bar-dev is the canonical name; .env (loaded by Justfile's dotenv-load) wins
# if the user has set their own. Defaulting here -- not just in
# cmd_setup_distrobox -- is what lets cmd_init reference $DEVTOOLS_DISTROBOX
# under `set -u` on a fresh install before any seed-write to .env has run.
: "${DEVTOOLS_DISTROBOX:=bar-dev}"
export DEVTOOLS_DISTROBOX

# WSL-only sister container that owns the filesystem mirror daemon (sync.py).
# Kept separate from bar-dev because Linux-native contributors never run sync
# and shouldn't pull watchman + pywatchman just to lint Lua. See
# docker/sync.Containerfile and scripts/sync.sh.
: "${DEVTOOLS_SYNC_DISTROBOX:=bar-sync}"
export DEVTOOLS_SYNC_DISTROBOX

# $'...' ANSI-C quoting embeds real ESC (0x1b) bytes so the variables work
# in `cat <<EOF`, `printf "%s"`, and `echo` without -e. Keeping `echo -e`
# in the helpers below is still fine — there's nothing left for -e to
# interpret in these strings, but the flag is harmless.
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'

info()  { echo -e "${BLUE}[info]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()   { echo -e "${RED}[error]${NC} $*"; }
step()  { echo -e "${CYAN}[step]${NC}  $*"; }

# ---------------------------------------------------------------------------
# Feature selection (single source of truth -- BAR_FEATURES in .env)
# ---------------------------------------------------------------------------

# True if the comma-separated feature list $1 contains tag $2. The one
# canonical copy -- setup.sh and repos.sh both call this.
features_include() {
    local IFS=','
    local f
    for f in $1; do
        [ "$f" = "$2" ] && return 0
    done
    return 1
}

# require_repo <feature-csv> <repo-dir> <human-name>
# Guard for recipes that operate on a cloned repo. Succeeds if the repo is
# materialized in the workspace; otherwise prints guidance that distinguishes
# "feature never selected" from "selected but not cloned", and returns 1.
# BAR_FEATURES reaches us as an env var via the Justfile's `set dotenv-load`.
require_repo() {
    local feats="$1" dir="$2" name="$3"
    [ -d "$DEVTOOLS_DIR/$dir" ] && return 0
    local f selected=0
    local IFS=','
    for f in $feats; do
        features_include "${BAR_FEATURES:-}" "$f" && { selected=1; break; }
    done
    if [ "$selected" = 1 ]; then
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

# Echo running engine processes that have the *local-build* binaries open --
# i.e. processes that `engine::build` is about to overwrite. A live local
# engine has those files mmap'd (Linux) / share-locked (Windows), so the
# install step would corrupt it or fail with EACCES via drvfs.
#
# Path-scoped on purpose: the user may be playtesting with `--engine alpha`
# or any non-local version, and rebuilding the local engine in that case is
# perfectly safe. We only refuse when the running spring is actually using
# our build target.
#
# Game dir comes from $1, falling back to $BAR_DATA_DIR. Returns 1 (with
# names on stdout) iff any local-build engine is alive.
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
        # Win32_Process.ExecutablePath is the canonical "where did this
        # process boot from" field; case-insensitive prefix match because
        # NTFS paths are case-insensitive.
        local matches
        matches="$(powershell.exe -NoProfile -NonInteractive -Command "
            Get-CimInstance Win32_Process -Filter \"Name='spring.exe' OR Name='Beyond-All-Reason.exe'\" 2>\$null |
              Where-Object { \$_.ExecutablePath -and \$_.ExecutablePath.StartsWith('$win_local', [StringComparison]::OrdinalIgnoreCase) } |
              Select-Object -ExpandProperty Name
        " 2>/dev/null | tr -d '\r' | sort -u | grep -v '^$' || true)"
        [ -n "$matches" ] && mapfile -t holders <<<"$matches"
    else
        # /proc/PID/exe is a magic symlink whose readlink gives the fully
        # resolved executable path, so we compare against the resolved
        # local-build path too (link::create symlinks it into the source
        # tree).
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

# Re-execute the calling script inside a distrobox if DEVTOOLS_DISTROBOX is set.
# Just writes shebang scripts to temp files under /run/user/... which isn't
# shared with distrobox, so we feed the script via stdin (< "$0") before exec.
# True if we're already inside a container -- either because we spawned it
# (_DEVTOOLS_IN_DISTROBOX) or because the user opened it interactively
# (/run/.containerenv from podman, /.dockerenv from docker). Used by both
# enter_distrobox and distrobox_exec_interactive so "what counts as
# in-container" lives in one place.
_in_container() {
    [ -n "${_DEVTOOLS_IN_DISTROBOX:-}" ] || [ -f /run/.containerenv ] || [ -f /.dockerenv ]
}

# Inverse of enter_distrobox: refuse to run if we're inside a container.
# Use at the top of recipes that need the host's docker / podman daemon
# (services::*, engine::build, etc.) so contributors who exec'd into
# bar-dev get a clear "wrong layer" message instead of a cryptic
# "docker: command not found" 127.
require_host() {
    if _in_container; then
        err "This recipe runs on the host (needs podman) -- not from inside bar-dev."
        info "  Exit the container ('exit' or Ctrl-D), then re-run."
        exit 1
    fi
}

# Auto-enter the configured distrobox and re-exec the rest of the calling
# script inside it. No-op when DEVTOOLS_DISTROBOX is unset or we're already
# in a container. Used at the top of recipe shell snippets.
enter_distrobox() {
    if [ -n "${DEVTOOLS_DISTROBOX:-}" ] && ! _in_container; then
        info "Entering distrobox '$DEVTOOLS_DISTROBOX'..."
        exec distrobox enter "$DEVTOOLS_DISTROBOX" -- \
            env _DEVTOOLS_IN_DISTROBOX=1 bash -s -- "$@" < "$0"
    fi
}

# Run a single interactive command inside the distrobox with a real PTY.
# Use this for REPLs / TUIs / shells where the inner command needs an
# attached terminal (busted shell, lua repl, ncurses tools). Differs from
# enter_distrobox: doesn't re-exec the calling script, just dispatches the
# given command and exits.
#
# script(1) is the PTY wrapper. distrobox-enter from a non-tty shell would
# otherwise hand the inner cmd a pipe and interactive prompts misbehave.
# `script -qec` parses its command argument via /bin/sh, so we re-quote
# every arg with printf %q to survive that round-trip.
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
