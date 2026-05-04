set export

DEVTOOLS_DIR := justfile_directory()

# Set up 1Password SSH agent (Windows + WSL bridge, or native Linux) and op CLI
op-setup *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    bash "$DEVTOOLS_DIR/scripts/ssh/setup-op-ssh.sh" {{args}}

# Just the WSL bridge half (assumes 1Password Desktop is already on Windows)
wsl-bridge:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    bash "$DEVTOOLS_DIR/scripts/ssh/setup-wsl-ssh.sh"

# Read-only health check: print SSH agent status and op CLI sign-in
doctor:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    info "SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-(unset)}"
    if ssh-add -l; then
        ok "ssh-add reached the agent."
    else
        warn "ssh-add could not list keys (rc=$?)."
    fi
    if command -v op >/dev/null; then
        if op whoami 2>&1; then
            ok "op CLI signed in."
        else
            warn "op CLI installed but not signed in (run: op signin)."
        fi
    else
        warn "op CLI not installed."
    fi
