#!/usr/bin/env bash
# Shared helpers for BAR-Devtools scripts.
# Source this file; it only defines functions and variables.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

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
enter_distrobox() {
    if [ -n "${DEVTOOLS_DISTROBOX:-}" ] && [ -z "${_DEVTOOLS_IN_DISTROBOX:-}" ]; then
        info "Entering distrobox '$DEVTOOLS_DISTROBOX'..."
        exec distrobox enter "$DEVTOOLS_DISTROBOX" -- \
            env _DEVTOOLS_IN_DISTROBOX=1 bash -s -- "$@" < "$0"
    fi
}
