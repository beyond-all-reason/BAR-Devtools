set export

DEVTOOLS_DIR := justfile_directory()
COMPOSE_FILE := DEVTOOLS_DIR / "docker-compose.dev.yml"
COMPOSE      := "docker compose -f " + COMPOSE_FILE
LOBBY_DIR    := DEVTOOLS_DIR / "bar-lobby"

# Start dev services. Options: lobby, spads
up *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    install_dockerignore

    start_lobby=0
    with_spads=0
    for arg in {{args}}; do
        case "$arg" in
            lobby|--lobby) start_lobby=1 ;;
            spads|--spads) with_spads=1 ;;
        esac
    done

    if [ "$with_spads" -eq 1 ]; then
        info "Starting PostgreSQL, Teiserver, and SPADS..."
        $COMPOSE --profile spads up -d --build
    else
        info "Starting PostgreSQL and Teiserver..."
        $COMPOSE up -d --build
    fi

    echo ""
    info "Waiting for Teiserver to become healthy (first run takes several minutes)..."
    echo "  Follow progress: just services::logs teiserver"
    echo ""

    attempts=0
    max_attempts=120
    while [ $attempts -lt $max_attempts ]; do
        health=$($COMPOSE ps teiserver --format '{{{{.Health}}}}' 2>/dev/null || echo "unknown")
        case "$health" in
            healthy)
                ok "Teiserver is healthy!"
                break
                ;;
            unhealthy)
                err "Teiserver failed to start. Check logs: just services::logs teiserver"
                exit 1
                ;;
            *)
                sleep 5
                attempts=$((attempts + 1))
                if [ $((attempts % 6)) -eq 0 ]; then
                    info "Still waiting... (${attempts}/${max_attempts}) - health: ${health}"
                fi
                ;;
        esac
    done

    if [ $attempts -ge $max_attempts ]; then
        err "Timed out waiting for Teiserver. Check logs: just services::logs teiserver"
        exit 1
    fi

    echo ""
    echo -e "${BOLD}=== Services Running ===${NC}"
    echo ""
    echo -e "  ${GREEN}Teiserver Web UI${NC}    http://localhost:4000"
    echo -e "  ${GREEN}Teiserver HTTPS${NC}     https://localhost:8888"
    echo -e "  ${GREEN}Spring Protocol${NC}     localhost:8200 (TCP) / :8201 (TLS)"
    echo -e "  ${GREEN}PostgreSQL${NC}          localhost:${BAR_POSTGRES_PORT:-5433}"
    echo ""
    echo -e "  ${BOLD}Login:${NC}  root@localhost / password"
    echo -e "  ${BOLD}SPADS bot:${NC}  spadsbot / password"
    if [ "$with_spads" -eq 1 ]; then
        echo ""
        echo -e "  SPADS is starting (check: just services::logs spads)"
    fi
    echo ""

    if [ "$start_lobby" -eq 1 ]; then
        if [ ! -d "$LOBBY_DIR" ]; then
            err "bar-lobby directory not found. Run 'just repos::clone' first."
            exit 1
        fi
        if ! command -v node &>/dev/null; then
            err "Node.js is required for bar-lobby. Run 'just setup::deps'."
            exit 1
        fi
        info "Installing bar-lobby dependencies..."
        cd "$LOBBY_DIR"
        npm install
        info "Starting bar-lobby dev server..."
        echo "  (Ctrl+C to stop the lobby; Docker services keep running)"
        echo ""
        __NV_PRIME_RENDER_OFFLOAD=1 \
        __GLX_VENDOR_LIBRARY_NAME=nvidia \
        LC_CTYPE=C \
        npm start -- -- --no-sandbox
    fi

# Stop all services
down:
    $COMPOSE --profile spads down

# Show running services
status:
    #!/usr/bin/env bash
    echo -e "\033[1m=== Service Status ===\033[0m"
    echo ""
    $COMPOSE --profile spads ps -a

# Tail service logs
logs service="":
    #!/usr/bin/env bash
    if [ -z "{{service}}" ]; then
        $COMPOSE --profile spads logs -f --tail=100
    else
        $COMPOSE --profile spads logs -f --tail=100 "{{service}}"
    fi

# Start bar-lobby dev server
lobby:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    if [ ! -d "$LOBBY_DIR" ]; then
        err "bar-lobby directory not found at: $LOBBY_DIR"
        err "Run 'just repos::clone' to clone repositories first."
        exit 1
    fi
    if ! command -v node &>/dev/null; then
        err "Node.js is required for bar-lobby. Run 'just setup::deps'."
        exit 1
    fi
    info "Installing bar-lobby dependencies..."
    cd "$LOBBY_DIR"
    npm install
    info "Starting bar-lobby dev server..."
    echo "  (Ctrl+C to stop the lobby; Docker services keep running)"
    echo ""
    __NV_PRIME_RENDER_OFFLOAD=1 \
    __GLX_VENDOR_LIBRARY_NAME=nvidia \
    LC_CTYPE=C \
    npm start -- -- --no-sandbox

# Open a shell in a container
shell service="teiserver":
    $COMPOSE --profile spads exec {{service}} bash

# Build Docker images
build:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    install_dockerignore
    info "Building Docker images..."
    info "  - Teiserver: compiling Elixir deps + generating TLS certs"
    info "  - SPADS: pulling pre-built image (badosu/spads:latest)"
    echo ""
    $COMPOSE build teiserver
    $COMPOSE --profile spads pull spads
    echo ""
    ok "Images built successfully."

# Destroy all data and rebuild from scratch
[confirm("This will destroy all data (database, SPADS state, engine cache). Continue?")]
reset:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    info "Stopping services and removing volumes..."
    $COMPOSE --profile spads down -v
    info "Rebuilding images from scratch..."
    $COMPOSE build --no-cache teiserver
    $COMPOSE --profile spads pull spads
    ok "Reset complete. Run 'just services::up' to start fresh."
