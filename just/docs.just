set export

DEVTOOLS_DIR := justfile_directory()
RECOIL_DIR   := DEVTOOLS_DIR / "RecoilEngine"
COMPOSE_FILE := DEVTOOLS_DIR / "docker-compose.dev.yml"
COMPOSE      := "podman compose -f " + COMPOSE_FILE

# Generate Lua API pages (full pipeline: extract -> JSON -> markdown)
generate:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_host
    {{COMPOSE}} run --rm recoil-docs lua_pages

# Extract Lua library locally (contexts branch), regen pages, start Hugo dev server.
server:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_host
    {{COMPOSE}} run --rm --service-ports recoil-docs server_full -- --bind 0.0.0.0

# Start Hugo dev server without regenerating anything
server-only:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_host
    {{COMPOSE}} run --rm --service-ports recoil-docs server -- --bind 0.0.0.0

# Rebuild the docs container image
build:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_host
    {{COMPOSE}} build recoil-docs

# TODO: doc/site/data/* are pipeline outputs tracked in git; prefer build-only artifacts.

# Reset generated doc data files
reset:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    info "Resetting doc site data in RecoilEngine..."
    cd "$RECOIL_DIR"
    git checkout -- doc/site/data/
    git clean -fd doc/site/data/
    ok "Doc data reset."
