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

# Verify the agent is usable end-to-end. Distinguishes the three failure
# modes contributors actually hit (no agent reachable / agent up but no
# keys / keys present but github.com rejects them) and prints the exact
# next step instead of letting the failure surface during their first
# `git push`. SSH_AUTH_SOCK must be set in the calling shell.
op_ssh_verify() {
    local listing rc
    # `if cmd; then ...; fi` for the substitution so set -e doesn't abort on
    # ssh-add's non-zero exits (1 = no keys, 2 = no agent) -- those are the
    # cases the rc==1/rc==2 branches below exist to diagnose.
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
    # github.com's SSH greeting ALWAYS exits 1 even on a successful auth
    # (it doesn't run a shell). Trailing `|| true` stops `set -e` from
    # aborting the function on the substitution — without it, the if/else
    # below never runs and the caller falsely reports op-setup as failed.
    local gh_out
    gh_out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                  -o ConnectTimeout=5 -T git@github.com 2>&1 || true)"
    # Success signal is the "Hi <user>! You've successfully authenticated"
    # message in stderr, not the exit code.
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

# Pin repos.local.conf to '@protocol ssh' once we've proven SSH works.
# Future `just repos::clone` / `just setup::init` runs will rewrite
# github.com URLs to SSH so clones/pushes use the bridged agent instead
# of HTTPS (which is slow over Plan 9 from WSL and prompts for a token).
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

# WSL-only. Echoes the Windows %USERPROFILE% as a WSL path (e.g. /mnt/c/Users/keith).
win_userprofile() {
    local raw
    # || true so set -e + pipefail doesn't abort here when cmd.exe interop
    # is missing -- the empty-$raw branch below is the intended diagnostic.
    raw="$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r\n')" || true
    [ -n "$raw" ] || { err "could not read Windows %USERPROFILE%"; return 1; }
    wslpath -u "$raw"
}
