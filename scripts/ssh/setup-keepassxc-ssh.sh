#!/usr/bin/env bash
# KeePassXC SSH agent setup -- STUB.
#
# KeePassXC has shipped an SSH agent integration for years: Settings ->
# SSH Agent -> "Enable SSH Agent integration." Keys with an attached
# private file get loaded into the running ssh-agent (NOT a Unix socket
# of its own); on Linux this is the user's existing $SSH_AUTH_SOCK, on
# Windows it's the OpenSSH service's named pipe. So unlike 1Password and
# Bitwarden, KeePassXC mostly needs the ssh-agent to *exist* and be
# reachable -- KeePassXC pushes keys into it on database unlock.
#
# Implementation notes for the contributor who picks this up:
#   - Linux: ensure SSH_AUTH_SOCK points at a running agent (xdg-ssh-agent,
#     gnome-keyring, or `ssh-agent -s` started from .bashrc -- see the
#     manual setup script for the bashrc snippet shape).
#   - Windows-from-WSL: bridge the OpenSSH service pipe with npiperelay
#     (same shape as the 1Password bridge but with pipe name
#     \\.\pipe\openssh-ssh-agent -- which IS the same pipe; KeePassXC
#     populates the OS agent rather than running its own).
#   - Verify with op_ssh_verify once SSH_AUTH_SOCK is set.

DEVTOOLS_DIR="${DEVTOOLS_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck source=../common.sh
source "$DEVTOOLS_DIR/scripts/common.sh"

err "KeePassXC SSH integration isn't wired up yet."
info "Pick this up from scripts/ssh/setup-keepassxc-ssh.sh -- it mostly"
info "needs to ensure ssh-agent is running and reachable; KeePassXC pushes"
info "keys into the OS agent on database unlock (it doesn't run its own)."
info "For now, run 'just ssh::manual-setup' to get a plain ssh-agent + key,"
info "or 'just ssh::op-setup' if you also use 1Password."
exit 1
