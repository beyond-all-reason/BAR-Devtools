set export

DEVTOOLS_DIR    := justfile_directory()
COMPOSE_FILE    := DEVTOOLS_DIR / "docker-compose.dev.yml"
COMPOSE         := "podman compose -f " + COMPOSE_FILE
TEISERVER_DIR   := DEVTOOLS_DIR / "teiserver"

[private]
require-setup:
    #!/usr/bin/env bash
    if [ ! -d "{{TEISERVER_DIR}}" ]; then
        echo "Error: teiserver is not cloned." >&2
        echo "Run: just setup::init" >&2
        exit 1
    fi

# Initialize and migrate the test database
setup-test-db: require-setup
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_host
    {{COMPOSE}} run --rm -e MIX_ENV=test --entrypoint "" \
        teiserver bash -c "mix ecto.create --quiet 2>/dev/null; mix ecto.migrate --quiet"

# Run teiserver mix tests
mix *args: require-setup
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_host
    {{COMPOSE}} run --rm -e MIX_ENV=test --entrypoint "" \
        -v {{TEISERVER_DIR}}/test:/app/test:z \
        teiserver mix test {{args}}

alias test := mix

# Drop into an interactive test shell for teiserver
test-shell: require-setup
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_host
    {{COMPOSE}} run --rm -e MIX_ENV=test --entrypoint "" \
        -v {{TEISERVER_DIR}}/test:/app/test:z \
        teiserver bash -c "echo 'Entering teiserver test shell (MIX_ENV=test). Type exit to return.' && exec bash"
