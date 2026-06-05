#!/usr/bin/env bash
# Shared helpers for scripts/ssh/*.sh. Source after scripts/common.sh.

have() { command -v "$1" >/dev/null 2>&1; }

is_wsl() {
    [ -n "${WSL_DISTRO_NAME:-}" ] || [ -f /proc/sys/fs/binfmt_misc/WSLInterop ]
}

# Sets OP_SSH_ENV to one of: wsl, fedora-atomic, linux-arch, linux-debian, linux-fedora, unknown.
detect_env() {
    if is_wsl; then
        OP_SSH_ENV=wsl
        return
    fi
    if [ -f /run/ostree-booted ] || have rpm-ostree; then
        OP_SSH_ENV=fedora-atomic
        return
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

# True if 1Password's SSH agent is reachable and has keys loaded.
op_ssh_already_active() {
    local sock
    for sock in "$HOME/.1password/agent.sock" "$HOME/.ssh/agent.sock"; do
        [ -S "$sock" ] || continue
        SSH_AUTH_SOCK="$sock" ssh-add -l >/dev/null 2>&1 && return 0
    done
    return 1
}

# Echo the path to the user's interactive shell rc file.
shellrc_path() {
    case "${SHELL:-}" in
        *zsh) echo "$HOME/.zshrc" ;;
        *)    echo "$HOME/.bashrc" ;;
    esac
}

# shellrc_apply <marker> <content>
# Idempotently install <content> in a marked block in the shell rc file.
# Sets SHELLRC_TARGET to the path touched.
shellrc_apply() {
    local marker="$1"; shift
    local content="$*"
    local rc; rc="$(shellrc_path)"
    SHELLRC_TARGET="$rc"
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

# Verify the agent end-to-end. SSH_AUTH_SOCK must be set in the calling shell.
op_ssh_verify() {
    local listing rc
    # ssh-add exits 1 = no keys, 2 = no agent; capture without tripping set -e.
    if listing="$(ssh-add -l 2>&1)"; then rc=0; else rc=$?; fi

    if [ $rc -eq 2 ]; then
        err "Could not reach the SSH agent at \$SSH_AUTH_SOCK ($SSH_AUTH_SOCK)."
        err "  Confirm 1Password Desktop is running and signed in, and that"
        err "  Settings → Developer → 'Use the SSH agent' is enabled."
        return 1
    fi
    if [ $rc -eq 1 ]; then
        warn "Agent is reachable but no SSH keys are loaded."
        warn "  Open 1Password and add an SSH key item (or unlock an existing"
        warn "  one), then re-run 'just ssh::op-setup'. Without a loaded key"
        warn "  the bridge succeeds silently and the first git operation"
        warn "  fails with 'Permission denied (publickey)'."
        return 1
    fi

    ok "Agent is live and ssh-add sees keys:"
    printf '%s\n' "$listing" | sed 's/^/    /'
    echo ""

    step "    Probing github.com for end-to-end auth"
    # github.com's SSH greeting always exits 1 (no shell); `|| true` keeps set -e calm.
    local gh_out
    gh_out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                  -o ConnectTimeout=5 -T git@github.com 2>&1 || true)"
    # Success signal is the "successfully authenticated" message, not the exit code.
    if printf '%s' "$gh_out" | grep -q "successfully authenticated"; then
        ok "github.com authenticated as $(printf '%s' "$gh_out" | sed -n 's/^Hi \([^!]*\)!.*/\1/p')."
        op_ssh_pin_protocol_ssh
    else
        warn "github.com did not accept any loaded key:"
        printf '%s\n' "$gh_out" | sed 's/^/    /'
        warn "  The agent is bridged correctly, but the keys 1Password is"
        warn "  exposing aren't registered on your GitHub account. Add one"
        warn "  at https://github.com/settings/keys (the public key for any"
        warn "  loaded item) and re-run."
    fi
}

# Pin repos.local.conf to '@protocol ssh' once SSH is proven working.
# Idempotent: skips if the user already set any @protocol directive.
op_ssh_pin_protocol_ssh() {
    local conf="${DEVTOOLS_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}/repos.local.conf"
    if [ -f "$conf" ] && grep -qE '^[[:space:]]*@protocol[[:space:]]' "$conf"; then
        info "repos.local.conf already pins @protocol — leaving it alone."
        return 0
    fi
    {
        [ -s "$conf" ] && echo ""
        echo "# Auto-pinned by just ssh::op-setup after github.com auth succeeded."
        echo "@protocol ssh"
    } >> "$conf"
    ok "Pinned @protocol ssh in $conf — clones/pushes will use the bridged agent."
}

# WSL-only. Echoes the Windows %USERPROFILE% as a WSL path.
win_userprofile() {
    local raw
    # || true: handle missing cmd.exe interop via the empty-$raw branch below.
    raw="$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r\n')" || true
    [ -n "$raw" ] || { err "could not read Windows %USERPROFILE%"; return 1; }
    wslpath -u "$raw"
}
