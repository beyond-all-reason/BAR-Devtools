set export

DEVTOOLS_DIR := justfile_directory()
COMPOSE_FILE := DEVTOOLS_DIR / "docker-compose.dev.yml"
COMPOSE      := "podman compose -f " + COMPOSE_FILE
REPOS_CONF   := DEVTOOLS_DIR / "repos.conf"
REPOS_LOCAL  := DEVTOOLS_DIR / "repos.local.conf"

# Full first-time setup: install deps, clone repos, build images
init *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/repos.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    cmd_init {{args}}

# Re-run setup, re-prompting every saved .env decision (features, ssh, ...)
reconfigure *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/repos.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    # BAR_RESET_CONFIG makes ensure_module re-prompt instead of reusing .env.
    export BAR_RESET_CONFIG=1
    cmd_init {{args}}

# Install system packages (git, podman/docker, distrobox)
deps:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    cmd_install_deps

# Build dev container image and create distrobox (--rebuild forces lux cache wipe)
distrobox *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    cmd_setup_distrobox {{args}}

# Wire your editor up for BAR development. Idempotent — re-runnable any time.
# `setup::init` calls this at the end too (gated on the Step 0/N opt-in), so
# the standalone recipe exists for "I changed my mind / something drifted."
# Direct invocation = explicit yes; wipe any prior answers so the sub-prompts
# fire fresh, then delegate to the shared shell helpers in scripts/setup.sh.
editor:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"

    sed -i '/^BAR_EDITOR_/d' "$DEVTOOLS_DIR/.env" 2>/dev/null || true
    editor_collect_state
    _editor_show_preamble
    echo "BAR_EDITOR_SETUP=yes" >> "$DEVTOOLS_DIR/.env"
    cmd_setup_editor

# Install git pre-commit hooks (stylua + luacheck) in BAR repo
hooks:
    just bar::setup-hooks

# Check prerequisites and build Docker images
check:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/repos.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    cmd_setup

# Diagnose your dev environment (read-only)
doctor:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/repos.sh"
    # setup.sh defines (and on its tail loads) the module registry; doctor
    # iterates it to show "what cmd_init recorded".
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    source "$DEVTOOLS_DIR/scripts/doctor.sh"
    cmd_doctor
