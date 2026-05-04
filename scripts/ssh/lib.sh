#!/usr/bin/env bash
# Shared helpers for scripts/ssh/*.sh.
# Source this file after scripts/common.sh; it only defines functions/variables.
#
# These helpers are deliberately self-contained so the SSH wizard can run on a
# fresh box before the rest of BAR-Devtools (setup.sh) is applicable.

have() { command -v "$1" >/dev/null 2>&1; }

is_wsl() {
    [ -n "${WSL_DISTRO_NAME:-}" ] || [ -f /proc/sys/fs/binfmt_misc/WSLInterop ]
}

# Sets OP_SSH_ENV to one of: wsl, bazzite, linux-arch, linux-debian, linux-fedora, unknown.
detect_env() {
    if is_wsl; then
        OP_SSH_ENV=wsl
        return
    fi
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [ "${VARIANT_ID:-}" = "bazzite" ] || [ "${ID:-}" = "bazzite" ]; then
            OP_SSH_ENV=bazzite
            return
        fi
    fi
    if have pacman; then OP_SSH_ENV=linux-arch
    elif have apt-get; then OP_SSH_ENV=linux-debian
    elif have dnf; then OP_SSH_ENV=linux-fedora
    else OP_SSH_ENV=unknown
    fi
}

pause() {
    step "$*"
    read -rp "       Press Enter when done... " _
}

# bashrc_apply <marker> <content>
# Idempotently install <content> between
#   # >>> <marker> >>>
#   # <<< <marker> <<<
# markers in ~/.bashrc. Replaces the block in place if it already exists.
bashrc_apply() {
    local marker="$1"; shift
    local content="$*"
    local rc="$HOME/.bashrc"
    local begin="# >>> ${marker} >>>"
    local end="# <<< ${marker} <<<"
    local tmp; tmp="$(mktemp)"

    touch "$rc"
    if grep -qF "$begin" "$rc"; then
        awk -v b="$begin" -v e="$end" -v body="$content" '
            $0 == b { print; print body; in_block=1; next }
            $0 == e { print; in_block=0; next }
            !in_block { print }
        ' "$rc" > "$tmp"
    else
        cat "$rc" > "$tmp"
        {
            echo ""
            echo "$begin"
            echo "$content"
            echo "$end"
        } >> "$tmp"
    fi
    mv "$tmp" "$rc"
}

# WSL-only. Echoes the Windows %USERPROFILE% as a WSL path (e.g. /mnt/c/Users/keith).
win_userprofile() {
    local raw
    raw="$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r\n')"
    [ -n "$raw" ] || { err "could not read Windows %USERPROFILE%"; return 1; }
    wslpath -u "$raw"
}
