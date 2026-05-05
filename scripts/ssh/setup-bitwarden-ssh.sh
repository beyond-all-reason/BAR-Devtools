#!/usr/bin/env bash
# Bitwarden SSH agent setup -- STUB.
#
# Bitwarden Desktop (>=2024.10) ships a built-in SSH agent: Settings ->
# Security -> SSH agent. On Linux it exposes a Unix socket; on Windows it
# uses a named pipe analogous to 1Password's, so the WSL bridge shape from
# scripts/ssh/setup-wsl-ssh.sh applies with the pipe name swapped.
#
# Implementation notes for the contributor who picks this up:
#   - Pipe name (Windows): \\.\pipe\com.bitwarden.bitwarden-ssh-agent
#     (subject to change; check the Bitwarden release notes).
#   - Linux socket: $XDG_RUNTIME_DIR/com.bitwarden.bitwarden-ssh-agent
#   - Reuse op_ssh_verify from lib.sh once SSH_AUTH_SOCK is wired up.
#   - bashrc_apply marker: "bitwarden-ssh-agent".

DEVTOOLS_DIR="${DEVTOOLS_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck source=../common.sh
source "$DEVTOOLS_DIR/scripts/common.sh"

err "Bitwarden SSH bridge isn't wired up yet."
info "Pick this up from scripts/ssh/setup-bitwarden-ssh.sh -- the 1Password"
info "scripts (setup-wsl-ssh.sh / setup-linux-ssh.sh) are the template."
info "For now, run 'just ssh::manual-setup' to get a plain ssh-agent + key,"
info "or 'just ssh::op-setup' if you also use 1Password."
exit 1
