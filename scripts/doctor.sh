#!/usr/bin/env bash
# Diagnostic checks for BAR-Devtools. Read-only — never modifies anything.
# Expects: DEVTOOLS_DIR, COMPOSE, REPOS_CONF, REPOS_LOCAL (exported by Justfile)

pass_count=0
warn_count=0
fail_count=0

_pass() { ok "$*";   pass_count=$((pass_count + 1)); }
_warn() { warn "$*"; warn_count=$((warn_count + 1)); }
_fail() { err "$*";  fail_count=$((fail_count + 1)); }


check_doctor_deps() {
  echo -e "${BOLD}System dependencies${NC}"

  if ! command -v git &>/dev/null; then
    _fail "git not installed"
    echo "       Run: just setup::deps"
  else
    _pass "git $(git --version | awk '{print $3}')"
  fi

  if ! command -v docker &>/dev/null; then
    _fail "Docker not installed"
    echo "       Run: just setup::deps"
  elif ! docker info &>/dev/null; then
    _fail "Docker daemon not running or permission denied"
    echo "       Start:  sudo systemctl start docker"
    echo "       Perms:  sudo usermod -aG docker \$USER  (then re-login)"
  elif ! docker compose version &>/dev/null; then
    _fail "Docker Compose V2 not installed"
    echo "       Run: just setup::deps"
  else
    _pass "Docker $(docker --version | awk '{print $3}' | tr -d ',') + Compose V2"
  fi

  if ! command -v distrobox &>/dev/null; then
    _warn "distrobox not installed (optional — needed for bar::lint, bar::fmt, lua::*)"
    echo "       Install: just setup::deps"
  else
    _pass "distrobox $(distrobox version 2>/dev/null | head -1)"
  fi

  echo ""
}


check_doctor_env() {
  echo -e "${BOLD}Environment${NC}"

  local env_file="$DEVTOOLS_DIR/.env"
  if [ -f "$env_file" ]; then
    _pass ".env file exists"
  else
    _warn ".env not found (created by just setup::distrobox)"
    echo "       Not required, but recipes needing distrobox won't auto-enter without it."
  fi

  if [ -n "${DEVTOOLS_DISTROBOX:-}" ]; then
    if command -v distrobox &>/dev/null && distrobox list 2>/dev/null | grep -q "$DEVTOOLS_DISTROBOX"; then
      _pass "DEVTOOLS_DISTROBOX=$DEVTOOLS_DISTROBOX (exists)"
    else
      _fail "DEVTOOLS_DISTROBOX=$DEVTOOLS_DISTROBOX (container not found)"
      echo "       Rebuild: just setup::distrobox"
    fi
  elif command -v distrobox &>/dev/null; then
    _warn "DEVTOOLS_DISTROBOX not set — distrobox recipes will fail"
    echo "       Run: just setup::distrobox"
  fi

  echo ""
}


check_doctor_ports() {
  echo -e "${BOLD}Ports${NC}"

  local pg_port="${BAR_POSTGRES_PORT:-5433}"
  local -A port_service=(
    [4000]="Teiserver HTTP"
    [$pg_port]="PostgreSQL"
    [8200]="Spring Protocol TCP"
    [8201]="Spring Protocol TLS"
    [8888]="Teiserver HTTPS"
  )

  local our_ports=""
  if docker compose -f "$DEVTOOLS_DIR/docker-compose.dev.yml" ps --format '{{.Ports}}' 2>/dev/null | grep -q .; then
    our_ports="$(docker compose -f "$DEVTOOLS_DIR/docker-compose.dev.yml" ps --format '{{.Ports}}' 2>/dev/null)"
  fi

  local conflict=0
  for port in 4000 "$pg_port" 8200 8201 8888; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      if echo "$our_ports" | grep -q ":${port}->" 2>/dev/null; then
        continue
      fi
      _warn "Port ${port} in use (${port_service[$port]}) — may conflict"
      conflict=1
    fi
  done

  if [ "$conflict" -eq 0 ]; then
    _pass "All required ports available (4000, ${pg_port}, 8200, 8201, 8888)"
  fi

  echo ""
}


check_doctor_repos() {
  echo -e "${BOLD}Repositories${NC}"

  load_repos_conf

  if [ "${#REPO_DIRS[@]}" -eq 0 ]; then
    _fail "No repositories configured (repos.conf missing or empty)"
    echo "       This shouldn't happen — is repos.conf present?"
    echo ""
    return
  fi

  local i missing_extras=()
  for i in "${!REPO_DIRS[@]}"; do
    local dir="${REPO_DIRS[$i]}"
    local group="${REPO_GROUPS[$i]}"
    local target="$DEVTOOLS_DIR/$dir"

    if [ -L "$target" ] && [ -d "$target" ]; then
      _pass "${dir} (${group}) — linked"
    elif [ -d "$target/.git" ]; then
      _pass "${dir} (${group})"
    elif [ "$group" = "core" ]; then
      _fail "${dir} (${group}) — not cloned"
      echo "       Run: just repos::clone core"
    else
      missing_extras+=("$dir")
    fi
  done

  if [ "${#missing_extras[@]}" -gt 0 ]; then
    _warn "${#missing_extras[@]} extra repos not cloned: ${missing_extras[*]}"
    echo "       Run: just repos::clone extra"
  fi

  echo ""
}


check_doctor_images() {
  echo -e "${BOLD}Docker images${NC}"

  if ! command -v docker &>/dev/null || ! docker info &>/dev/null; then
    _warn "Skipping — Docker not available"
    echo ""
    return
  fi

  local project_name
  project_name="$(basename "$DEVTOOLS_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_-')"
  if docker compose -f "$DEVTOOLS_DIR/docker-compose.dev.yml" images teiserver --format '{{.Repository}}' 2>/dev/null | grep -q .; then
    _pass "Teiserver image built"
  elif [ ! -d "$DEVTOOLS_DIR/teiserver" ]; then
    _fail "Teiserver image not built (teiserver repo not cloned)"
    echo "       Run: just repos::clone core && just services::build"
  else
    _fail "Teiserver image not built"
    echo "       Run: just services::build"
  fi

  if docker image inspect "badosu/spads:latest" &>/dev/null; then
    _pass "SPADS image available"
  else
    _warn "SPADS image not pulled (optional)"
    echo "       Run: just services::build"
  fi

  echo ""
}


check_doctor_services() {
  echo -e "${BOLD}Running services${NC}"

  if ! command -v docker &>/dev/null || ! docker info &>/dev/null; then
    _warn "Skipping — Docker not available"
    echo ""
    return
  fi

  local compose="docker compose -f $DEVTOOLS_DIR/docker-compose.dev.yml"
  local any_running=0

  for svc in postgres teiserver; do
    local state health
    state="$($compose ps "$svc" --format '{{.State}}' 2>/dev/null)"

    if [ -z "$state" ]; then
      info "  ${svc} — not running"
      continue
    fi

    any_running=1
    health="$($compose ps "$svc" --format '{{.Health}}' 2>/dev/null)"

    if [ "$state" = "running" ] && [ "$health" = "healthy" ]; then
      _pass "${svc} — running (healthy)"
    elif [ "$state" = "running" ] && [ "$health" = "starting" ]; then
      _warn "${svc} — running (still starting)"
    elif [ "$state" = "running" ]; then
      _warn "${svc} — running (health: ${health:-unknown})"
    else
      _fail "${svc} — ${state}"
      echo "       Check: just services::logs ${svc}"
    fi
  done

  local spads_state
  spads_state="$($compose --profile spads ps spads --format '{{.State}}' 2>/dev/null)"
  if [ -n "$spads_state" ]; then
    any_running=1
    if [ "$spads_state" = "running" ]; then
      _pass "spads — running"
    else
      _fail "spads — ${spads_state}"
      echo "       Check: just services::logs spads"
    fi
  else
    info "  spads — not running (optional)"
  fi

  if [ "$any_running" -eq 0 ]; then
    info "  No services running. Start with: just services::up"
  fi

  echo ""
}


cmd_doctor() {
  echo -e "${BOLD}=== BAR Devtools Doctor ===${NC}"
  echo ""

  check_doctor_deps
  check_doctor_env
  check_doctor_ports
  check_doctor_repos
  check_doctor_images
  check_doctor_services

  echo -e "${BOLD}Summary${NC}"
  local summary=""
  summary+="${GREEN}${pass_count} passed${NC}"
  if [ "$warn_count" -gt 0 ]; then
    summary+=", ${YELLOW}${warn_count} warnings${NC}"
  fi
  if [ "$fail_count" -gt 0 ]; then
    summary+=", ${RED}${fail_count} failures${NC}"
  fi
  echo -e "  ${summary}"

  if [ "$fail_count" -gt 0 ]; then
    echo ""
    echo "  Fix failures above, then re-run: just doctor"
    return 1
  elif [ "$warn_count" -gt 0 ]; then
    echo ""
    echo "  Warnings are non-blocking but may affect some workflows."
  fi
}
