set export

DEVTOOLS_DIR := justfile_directory()

# Set up 1Password SSH agent (Windows + WSL bridge, or native Linux) and op CLI
op-setup *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    bash "$DEVTOOLS_DIR/scripts/ssh/setup-op-ssh.sh" {{args}}

# Generate ~/.ssh/id_ed25519, start ssh-agent, walk through GitHub key registration
manual-setup *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    bash "$DEVTOOLS_DIR/scripts/ssh/setup-manual-ssh.sh" {{args}}

# Bitwarden Desktop SSH agent (stub -- not yet implemented)
bitwarden-setup *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    bash "$DEVTOOLS_DIR/scripts/ssh/setup-bitwarden-ssh.sh" {{args}}

# KeePassXC SSH integration (stub -- not yet implemented)
keepassxc-setup *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    bash "$DEVTOOLS_DIR/scripts/ssh/setup-keepassxc-ssh.sh" {{args}}

# Just the WSL bridge half (assumes 1Password Desktop is already on Windows)
wsl-bridge:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    bash "$DEVTOOLS_DIR/scripts/ssh/setup-wsl-ssh.sh"

# Read-only health check: agent reachable, keys loaded, GitHub accepts them
doctor:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/ssh/lib.sh"
    info "SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-(unset)}"
    op_ssh_verify || true
    if command -v op >/dev/null; then
        if op whoami 2>&1; then
            ok "op CLI signed in."
        else
            warn "op CLI installed but not signed in (run: op signin)."
        fi
    fi
