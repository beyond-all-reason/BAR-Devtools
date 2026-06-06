#!/usr/bin/env bash
# Manual SSH setup: generate a key, run a plain ssh-agent, register the public
# key on GitHub, and verify. Fallback for contributors without a password manager.
set -euo pipefail

DEVTOOLS_DIR="${DEVTOOLS_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck source=../common.sh
source "$DEVTOOLS_DIR/scripts/common.sh"
# shellcheck source=./lib.sh
source "$DEVTOOLS_DIR/scripts/ssh/lib.sh"

KEY_PATH="$HOME/.ssh/id_ed25519"
KEY_TYPE="ed25519"

step "1/4 SSH key"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ -f "$KEY_PATH" ]; then
    info "Existing key at $KEY_PATH — keeping it."
else
    info "Generating a new $KEY_TYPE key at $KEY_PATH."
    info "  You can leave the passphrase blank for unattended use, but a"
    info "  passphrase + ssh-agent caching is the recommended posture."
    ssh-keygen -t "$KEY_TYPE" -C "$(whoami)@$(hostname) (BAR-Devtools)" -f "$KEY_PATH"
    ok "Key generated."
fi

step "2/4 ssh-agent"
if ! ssh-add -l >/dev/null 2>&1; then
    if [ -z "${SSH_AUTH_SOCK:-}" ]; then
        info "No ssh-agent in this shell — starting one."
        eval "$(ssh-agent -s)" >/dev/null
    fi
fi
if ! ssh-add -L 2>/dev/null | grep -qF "$(ssh-keygen -y -f "$KEY_PATH")"; then
    info "Adding $KEY_PATH to the agent (you'll be prompted if it has a passphrase)."
    ssh-add "$KEY_PATH"
fi

shellrc_apply "manual-ssh-agent" "$(cat <<BLOCK
# Start a user ssh-agent on first interactive shell and reuse it across shells.
SSH_ENV="\$HOME/.ssh/agent-env"
if [ ! -S "\${SSH_AUTH_SOCK:-}" ]; then
    if [ -f "\$SSH_ENV" ]; then
        # shellcheck disable=SC1090
        . "\$SSH_ENV" >/dev/null
    fi
    if ! ssh-add -l >/dev/null 2>&1; then
        ssh-agent -s > "\$SSH_ENV"
        chmod 600 "\$SSH_ENV"
        # shellcheck disable=SC1090
        . "\$SSH_ENV" >/dev/null
        ssh-add "$KEY_PATH" 2>/dev/null || true
    fi
fi
export SSH_AUTH_SOCK SSH_AGENT_PID
BLOCK
)"
ok "Updated ${SHELLRC_TARGET/#$HOME/~} (block: manual-ssh-agent)."

step "3/4 Register the public key on GitHub"
echo ""
echo "    Open this page in a browser (logged in as the GitHub account you'll"
echo "    contribute from):"
echo ""
echo "        https://github.com/settings/ssh/new"
echo ""
echo "    Title:  $(hostname) (BAR-Devtools)"
echo "    Type:   Authentication Key"
echo "    Key:"
echo ""
sed 's/^/        /' "${KEY_PATH}.pub"
echo ""
read -rp "    Press Enter once you've added the key... " _

step "4/4 Verify"
op_ssh_verify
echo ""
info "Open a new shell to pick up the ${SHELLRC_TARGET/#$HOME/~} snippet automatically."
