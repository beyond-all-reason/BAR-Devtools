#!/usr/bin/env bash
# 1Password SSH agent + CLI bootstrap.
# Detects environment and dispatches to the WSL or native-Linux wizard.
set -euo pipefail

DEVTOOLS_DIR="${DEVTOOLS_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck source=../common.sh
source "$DEVTOOLS_DIR/scripts/common.sh"
# shellcheck source=./lib.sh
source "$DEVTOOLS_DIR/scripts/ssh/lib.sh"

detect_env

cat <<EOF
${BOLD}1Password SSH agent setup${NC}

Detected environment: ${BOLD}${OP_SSH_ENV}${NC}

This wizard will:
  1. Install 1Password Desktop (and CLI) where it's missing.
  2. Pause while you enable "Use the SSH agent" + "Integrate with 1Password CLI"
     in 1Password's settings — those toggles are GUI-only.
  3. On WSL: install socat + npiperelay.exe and bridge the Windows agent.
     On native Linux: point SSH_AUTH_SOCK at ~/.1password/agent.sock.
  4. Append an idempotent block to your shell rc (~/.zshrc if $SHELL is zsh,
     otherwise ~/.bashrc) so the agent is wired on every shell.
  5. Test with ssh-add -l.

Re-running is safe: every step checks before acting, and the rc block is
replaced in place rather than duplicated.

EOF

case "$OP_SSH_ENV" in
    wsl)
        exec bash "$DEVTOOLS_DIR/scripts/ssh/setup-wsl-ssh.sh" "$@"
        ;;
    bazzite|linux-arch|linux-debian|linux-fedora)
        exec bash "$DEVTOOLS_DIR/scripts/ssh/setup-linux-ssh.sh" "$@"
        ;;
    *)
        err "Unsupported environment. This wizard supports WSL2 and native Linux (Bazzite/Arch/Debian/Fedora)."
        exit 1
        ;;
esac
