#!/usr/bin/env bash
# Shared helpers for BAR-Devtools scripts.
# Source this file; it only defines functions and variables.

# bar-dev is the canonical name; .env (loaded by Justfile's dotenv-load) wins
# if the user has set their own. Defaulting here -- not just in
# cmd_setup_distrobox -- is what lets cmd_init reference $DEVTOOLS_DISTROBOX
# under `set -u` on a fresh install before any seed-write to .env has run.
: "${DEVTOOLS_DISTROBOX:=bar-dev}"
export DEVTOOLS_DISTROBOX

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

    if command -v docker &>/dev/null; then
        warn "Retrying removal via docker..."
        docker run --rm -v "$parent:/p:z" alpine rm -rf "/p/$name"
        return $?
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
        err "This recipe runs on the host (needs docker / podman) -- not from inside bar-dev."
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
