#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.dev.yml"
COMPOSE="docker compose -f $COMPOSE_FILE"
LOBBY_DIR="$SCRIPT_DIR/bar-lobby"
REPOS_CONF="$SCRIPT_DIR/repos.conf"
REPOS_LOCAL="$SCRIPT_DIR/repos.local.conf"

detect_game_dir() {
  if [ -n "${BAR_GAME_DIR:-}" ]; then
    echo "$BAR_GAME_DIR"
    return 0
  fi
  local xdg_state="${XDG_STATE_HOME:-$HOME/.local/state}"
  local candidate="$xdg_state/Beyond All Reason"
  if [ -d "$candidate" ]; then
    echo "$candidate"
    return 0
  fi
  return 1
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${BLUE}[info]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()   { echo -e "${RED}[error]${NC} $*"; }
step()  { echo -e "${CYAN}[step]${NC}  $*"; }

# ===========================================================================
# Distro detection
# ===========================================================================

detect_distro() {
  if command -v pacman &>/dev/null; then
    echo "arch"
  elif command -v apt-get &>/dev/null; then
    echo "debian"
  elif command -v dnf &>/dev/null; then
    echo "fedora"
  else
    echo "unknown"
  fi
}

pkg_install_cmd() {
  case "$(detect_distro)" in
    arch)   echo "sudo pacman -S --needed" ;;
    debian) echo "sudo apt install -y" ;;
    fedora) echo "sudo dnf install -y" ;;
    *)      echo "" ;;
  esac
}

# Map generic package names to distro-specific ones
pkg_name() {
  local generic="$1"
  local distro
  distro="$(detect_distro)"
  case "${distro}:${generic}" in
    arch:docker)           echo "docker" ;;
    arch:docker-compose)   echo "docker-compose" ;;
    arch:git)              echo "git" ;;
    arch:nodejs)           echo "nodejs npm" ;;
    debian:docker)         echo "docker.io" ;;
    debian:docker-compose) echo "docker-compose-plugin" ;;
    debian:git)            echo "git" ;;
    debian:nodejs)         echo "nodejs npm" ;;
    fedora:docker)         echo "docker-ce docker-ce-cli containerd.io" ;;
    fedora:docker-compose) echo "docker-compose-plugin" ;;
    fedora:git)            echo "git" ;;
    fedora:nodejs)         echo "nodejs npm" ;;
    *)                     echo "$generic" ;;
  esac
}

# ===========================================================================
# Prerequisite checks
# ===========================================================================

check_git() {
  if ! command -v git &>/dev/null; then
    err "git is not installed."
    return 1
  fi
  ok "git $(git --version | awk '{print $3}') detected"
}

check_docker() {
  if ! command -v docker &>/dev/null; then
    err "Docker is not installed."
    return 1
  fi
  if ! docker info &>/dev/null; then
    err "Docker daemon is not running or current user lacks permissions."
    echo ""
    echo "  Start the daemon:   sudo systemctl start docker"
    echo "  Enable on boot:     sudo systemctl enable docker"
    echo "  Add yourself:       sudo usermod -aG docker \$USER  (then re-login)"
    echo ""
    return 1
  fi
  if ! docker compose version &>/dev/null; then
    err "Docker Compose V2 plugin is not installed."
    return 1
  fi
  ok "Docker $(docker --version | awk '{print $3}' | tr -d ',') + Compose V2 detected"
}

check_node() {
  if ! command -v node &>/dev/null; then
    warn "Node.js not found (needed for bar-lobby only)."
    return 1
  fi
  ok "Node.js $(node --version) detected"
}

check_ports() {
  local pg_port="${BAR_POSTGRES_PORT:-5433}"
  local ports=(4000 "$pg_port" 8200 8201 8888)
  local conflict=0
  for port in "${ports[@]}"; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      warn "Port ${port} is already in use"
      conflict=1
    fi
  done
  if [ "$conflict" -eq 1 ]; then
    warn "Some ports are in use. Services binding to those ports may fail to start."
  else
    ok "Required ports available (4000, ${pg_port}, 8200, 8201, 8888)"
  fi
}

check_prerequisites() {
  echo -e "${BOLD}Checking prerequisites...${NC}"
  echo ""
  local failed=0
  check_git    || failed=1
  check_docker || failed=1
  check_node   || true
  check_ports
  echo ""
  if [ "$failed" -ne 0 ]; then
    err "Missing required prerequisites. Run './devtools.sh install-deps' or fix manually."
    return 1
  fi
}

# ===========================================================================
# Repository management
# ===========================================================================

# Parse repos.conf (with repos.local.conf overrides) into parallel arrays.
# Populates: REPO_DIRS[], REPO_URLS[], REPO_BRANCHES[], REPO_GROUPS[], REPO_LOCAL_PATHS[]
declare -a REPO_DIRS=() REPO_URLS=() REPO_BRANCHES=() REPO_GROUPS=() REPO_LOCAL_PATHS=()

load_repos_conf() {
  REPO_DIRS=(); REPO_URLS=(); REPO_BRANCHES=(); REPO_GROUPS=(); REPO_LOCAL_PATHS=()
  local -A seen=()

  _parse_conf() {
    local file="$1"
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"                        # strip comments
      line="$(echo "$line" | xargs 2>/dev/null || true)"  # trim whitespace
      [ -z "$line" ] && continue
      local dir url branch group local_path
      read -r dir url branch group local_path <<< "$line"
      [ -z "$dir" ] || [ -z "$url" ] && continue
      branch="${branch:-master}"
      group="${group:-extra}"
      # Expand ~ in local_path
      local_path="${local_path/#\~/$HOME}"
      seen[$dir]="$url $branch $group $local_path"
    done < "$file"
  }

  _parse_conf "$REPOS_CONF"
  _parse_conf "$REPOS_LOCAL"   # local overrides win

  local dir
  for dir in "${!seen[@]}"; do
    local url branch group local_path
    read -r url branch group local_path <<< "${seen[$dir]}"
    REPO_DIRS+=("$dir")
    REPO_URLS+=("$url")
    REPO_BRANCHES+=("$branch")
    REPO_GROUPS+=("$group")
    REPO_LOCAL_PATHS+=("$local_path")
  done
}

clone_or_update_repo() {
  local dir="$1" url="$2" branch="$3" local_path="${4:-}" target="$SCRIPT_DIR/$dir"

  if [ -n "$local_path" ]; then
    if [ ! -d "$local_path" ]; then
      warn "  ${dir}: local path does not exist: ${local_path}"
      return 1
    fi
    if [ -L "$target" ]; then
      local current_link
      current_link="$(readlink "$target")"
      if [ "$current_link" = "$local_path" ]; then
        ok "  ${dir}: linked -> ${local_path}"
      else
        warn "  ${dir}: symlink points to ${current_link}, config says ${local_path}"
        info "  ${dir}: updating symlink..."
        rm "$target"
        ln -s "$local_path" "$target"
        ok "  ${dir}: linked -> ${local_path}"
      fi
    elif [ -d "$target" ]; then
      warn "  ${dir}: exists as a real directory but config says link to ${local_path}"
      warn "  ${dir}: remove it manually to use the local path"
    else
      ln -s "$local_path" "$target"
      ok "  ${dir}: linked -> ${local_path}"
    fi
    return 0
  fi

  if [ -d "$target/.git" ]; then
    local current_url
    current_url="$(git -C "$target" remote get-url origin 2>/dev/null || true)"
    if [ "$current_url" != "$url" ] && [ -n "$current_url" ]; then
      warn "  ${dir}: origin is ${current_url}"
      warn "  ${dir}: config says ${url}"
      warn "  ${dir}: add to repos.local.conf to set your preferred remote"
    fi
    info "  ${dir}: fetching latest..."
    git -C "$target" fetch origin --quiet 2>/dev/null || warn "  ${dir}: fetch failed (offline?)"
    local current_branch
    current_branch="$(git -C "$target" branch --show-current 2>/dev/null)"
    if [ -n "$current_branch" ] && [ "$current_branch" != "$branch" ]; then
      info "  ${dir}: on branch '${current_branch}' (config says '${branch}')"
    fi
  else
    info "  ${dir}: cloning ${url} (branch: ${branch})..."
    git clone --branch "$branch" "$url" "$target" 2>&1 | sed 's/^/    /'
  fi
}

cmd_clone() {
  local group_filter="${1:-all}"

  load_repos_conf

  if [ "${#REPO_DIRS[@]}" -eq 0 ]; then
    err "No repositories found in repos.conf"
    exit 1
  fi

  echo -e "${BOLD}=== Cloning / Updating Repositories ===${NC}"
  echo ""

  if [ -f "$REPOS_LOCAL" ]; then
    info "Using overrides from repos.local.conf"
    echo ""
  fi

  local i cloned=0 updated=0 skipped=0 linked=0
  for i in "${!REPO_DIRS[@]}"; do
    local dir="${REPO_DIRS[$i]}"
    local url="${REPO_URLS[$i]}"
    local branch="${REPO_BRANCHES[$i]}"
    local group="${REPO_GROUPS[$i]}"
    local local_path="${REPO_LOCAL_PATHS[$i]}"

    if [ "$group_filter" != "all" ] && [ "$group" != "$group_filter" ]; then
      skipped=$((skipped + 1))
      continue
    fi

    if [ -n "$local_path" ]; then
      clone_or_update_repo "$dir" "$url" "$branch" "$local_path"
      linked=$((linked + 1))
    elif [ -d "$SCRIPT_DIR/$dir/.git" ]; then
      clone_or_update_repo "$dir" "$url" "$branch"
      updated=$((updated + 1))
    else
      clone_or_update_repo "$dir" "$url" "$branch"
      cloned=$((cloned + 1))
    fi
  done

  echo ""
  local summary="${cloned} cloned, ${updated} updated, ${skipped} skipped"
  [ "$linked" -gt 0 ] && summary+=", ${linked} linked"
  ok "Repos: ${summary}"
}

cmd_repos() {
  load_repos_conf

  echo -e "${BOLD}=== Repository Status ===${NC}"
  echo ""
  printf "  ${DIM}%-24s %-8s %-18s %s${NC}\n" "DIRECTORY" "GROUP" "BRANCH" "STATUS"
  echo "  $(printf '%.0s-' {1..80})"

  local i
  for i in "${!REPO_DIRS[@]}"; do
    local dir="${REPO_DIRS[$i]}"
    local url="${REPO_URLS[$i]}"
    local branch="${REPO_BRANCHES[$i]}"
    local group="${REPO_GROUPS[$i]}"
    local local_path="${REPO_LOCAL_PATHS[$i]}"
    local target="$SCRIPT_DIR/$dir"

    local status current_branch
    if [ -L "$target" ]; then
      local link_dest
      link_dest="$(readlink "$target")"
      if [ -d "$target/.git" ]; then
        current_branch="$(git -C "$target" branch --show-current 2>/dev/null || echo "detached")"
        local dirty=""
        if ! git -C "$target" diff --quiet 2>/dev/null || ! git -C "$target" diff --cached --quiet 2>/dev/null; then
          dirty=" ${YELLOW}*dirty*${NC}"
        fi
        status="${CYAN}local${NC}${dirty} -> ${link_dest}"
      else
        status="${RED}broken link${NC} -> ${link_dest}"
        current_branch="-"
      fi
    elif [ -d "$target/.git" ]; then
      current_branch="$(git -C "$target" branch --show-current 2>/dev/null || echo "detached")"
      local dirty=""
      if ! git -C "$target" diff --quiet 2>/dev/null || ! git -C "$target" diff --cached --quiet 2>/dev/null; then
        dirty=" ${YELLOW}*dirty*${NC}"
      fi
      if [ "$current_branch" = "$branch" ]; then
        status="${GREEN}ok${NC}${dirty}"
      else
        status="${YELLOW}branch: ${current_branch}${NC}${dirty}"
      fi
    else
      status="${RED}missing${NC}"
      current_branch="-"
    fi

    printf "  %-24s %-8s %-18s %b\n" "$dir" "$group" "$current_branch" "$status"
  done
  echo ""
}

# ===========================================================================
# Dependency installation
# ===========================================================================

cmd_install_deps() {
  echo -e "${BOLD}=== Install System Dependencies ===${NC}"
  echo ""

  local distro
  distro="$(detect_distro)"
  local install_cmd
  install_cmd="$(pkg_install_cmd)"

  if [ "$distro" = "unknown" ] || [ -z "$install_cmd" ]; then
    err "Unsupported distro. Install these manually: git, docker, docker-compose, nodejs, npm"
    exit 1
  fi

  info "Detected distro: ${BOLD}${distro}${NC}"
  echo ""

  local missing=()

  if ! command -v git &>/dev/null; then
    missing+=("git")
  fi
  if ! command -v docker &>/dev/null; then
    missing+=("docker")
  fi
  if ! docker compose version &>/dev/null 2>&1; then
    missing+=("docker-compose")
  fi
  if ! command -v node &>/dev/null; then
    missing+=("nodejs")
  fi

  if [ "${#missing[@]}" -eq 0 ]; then
    ok "All dependencies already installed."
    echo ""

    if ! docker info &>/dev/null; then
      warn "Docker is installed but the daemon isn't running or you lack permissions."
      echo ""
      echo "  sudo systemctl start docker"
      echo "  sudo systemctl enable docker"
      echo "  sudo usermod -aG docker \$USER   # then re-login"
      echo ""
    fi
    return 0
  fi

  local packages=""
  for dep in "${missing[@]}"; do
    packages+=" $(pkg_name "$dep")"
  done

  info "Missing: ${missing[*]}"
  info "Will run: ${install_cmd}${packages}"
  echo ""

  read -rp "Install now? [Y/n] " confirm
  if [[ "$confirm" =~ ^[Nn]$ ]]; then
    echo "Skipped. Install manually and retry."
    return 1
  fi

  $install_cmd $packages

  echo ""

  if [[ " ${missing[*]} " == *" docker "* ]]; then
    info "Enabling and starting Docker daemon..."
    sudo systemctl enable --now docker 2>/dev/null || true

    if ! groups | grep -qw docker; then
      info "Adding $USER to the docker group (re-login required)..."
      sudo usermod -aG docker "$USER"
      warn "You need to log out and back in for Docker group membership to take effect."
      warn "After re-login, run: ./devtools.sh init"
      return 0
    fi
  fi

  ok "Dependencies installed successfully."
}

# ===========================================================================
# Docker helpers
# ===========================================================================

install_dockerignore() {
  local target="$SCRIPT_DIR/teiserver/.dockerignore"
  local source="$SCRIPT_DIR/docker/teiserver.dockerignore"
  if [ -f "$source" ] && [ ! -f "$target" ]; then
    cp "$source" "$target"
    info "Installed .dockerignore for teiserver build context"
  fi
}

cmd_build() {
  install_dockerignore

  info "Building Docker images..."
  info "  - Teiserver: compiling Elixir deps + generating TLS certs"
  info "  - SPADS: pulling pre-built image (badosu/spads:latest)"
  echo ""
  $COMPOSE build teiserver
  $COMPOSE --profile spads pull spads
  echo ""
  ok "Images built successfully."
}

# ===========================================================================
# Engine
# ===========================================================================

cmd_engine() {
  local subcmd="${1:-}"
  case "$subcmd" in
    build)
      shift
      local build_script="$SCRIPT_DIR/RecoilEngine/docker-build-v2/build.sh"
      if [ ! -f "$build_script" ]; then
        err "RecoilEngine not found. Clone it first: ./devtools.sh clone extra"
        exit 1
      fi
      exec "$build_script" "$@"
      ;;
    *)
      err "Usage: ./devtools.sh engine build [args...]"
      echo ""
      echo "  Wraps RecoilEngine/docker-build-v2/build.sh with full flag pass-through."
      echo ""
      echo "  Examples:"
      echo "    ./devtools.sh engine build linux"
      echo "    ./devtools.sh engine build linux -DCMAKE_BUILD_TYPE=Release"
      echo "    ./devtools.sh engine build linux -DCMAKE_BUILD_TYPE=Release -DTRACY_ENABLE=ON"
      echo "    ./devtools.sh engine build --help"
      exit 1
      ;;
  esac
}

# ===========================================================================
# Game directory linking
# ===========================================================================

cmd_link() {
  local target="${1:-}"
  local game_dir
  game_dir="$(detect_game_dir 2>/dev/null)" || true

  if [ -z "$target" ]; then
    echo -e "${BOLD}=== Symlink Status ===${NC}"
    echo ""
    if [ -z "$game_dir" ]; then
      warn "Game directory not found. Set BAR_GAME_DIR env var or install BAR to the default location."
      echo ""
      return 0
    fi
    info "Game directory: ${game_dir}"
    echo ""

    local -A link_map=(
      [engine]="$game_dir/engine/local-build"
      [chobby]="$game_dir/games/BYAR-Chobby"
      [bar]="$game_dir/games/Beyond-All-Reason"
    )
    for name in engine chobby bar; do
      local link_path="${link_map[$name]}"
      if [ -L "$link_path" ]; then
        local link_target
        link_target="$(readlink -f "$link_path" 2>/dev/null || echo "?")"
        printf "  %-10s ${GREEN}linked${NC} -> %s\n" "$name" "$link_target"
      elif [ -e "$link_path" ]; then
        printf "  %-10s ${YELLOW}exists (not a symlink)${NC} at %s\n" "$name" "$link_path"
      else
        printf "  %-10s ${DIM}not linked${NC}\n" "$name"
      fi
    done
    echo ""
    return 0
  fi

  if [ -z "$game_dir" ]; then
    err "Game directory not found. Set BAR_GAME_DIR env var or install BAR to the default location."
    exit 1
  fi

  local source_path link_path
  case "$target" in
    engine)
      source_path="$SCRIPT_DIR/RecoilEngine/build-linux/install"
      link_path="$game_dir/engine/local-build"
      ;;
    chobby)
      source_path="$SCRIPT_DIR/BYAR-Chobby"
      link_path="$game_dir/games/BYAR-Chobby"
      ;;
    bar)
      source_path="$SCRIPT_DIR/Beyond-All-Reason"
      link_path="$game_dir/games/Beyond-All-Reason"
      ;;
    *)
      err "Unknown link target: $target"
      echo "  Valid targets: engine, chobby, bar"
      exit 1
      ;;
  esac

  if [ ! -e "$source_path" ] && [ ! -L "$source_path" ]; then
    err "Source not found: $source_path"
    if [ "$target" = "engine" ]; then
      echo "  Build the engine first: ./devtools.sh engine build linux"
    else
      echo "  Clone the repo first: ./devtools.sh clone extra"
    fi
    exit 1
  fi

  if [ -L "$link_path" ]; then
    info "Replacing existing symlink at $link_path"
    rm "$link_path"
  elif [ -e "$link_path" ]; then
    warn "$link_path already exists and is not a symlink. Skipping."
    warn "Remove it manually if you want to replace it."
    return 1
  fi

  mkdir -p "$(dirname "$link_path")"
  ln -s "$source_path" "$link_path"
  ok "Linked $target: $link_path -> $source_path"
}

# ===========================================================================
# Main commands
# ===========================================================================

cmd_init() {
  echo -e "${BOLD}==========================================${NC}"
  echo -e "${BOLD}  BAR Dev Environment - First Time Setup${NC}"
  echo -e "${BOLD}==========================================${NC}"
  echo ""

  step "1/5  Checking & installing dependencies"
  echo ""
  local deps_ok=0
  if check_git &>/dev/null && check_docker &>/dev/null; then
    deps_ok=1
    ok "Core dependencies (git, docker) already installed."
    check_node || true
  else
    cmd_install_deps || { err "Dependency installation failed. Fix and retry."; exit 1; }
    deps_ok=1
  fi
  echo ""

  step "2/5  Cloning repositories"
  echo ""
  if [ ! -f "$REPOS_CONF" ]; then
    err "repos.conf not found at: $REPOS_CONF"
    exit 1
  fi
  cmd_clone core
  echo ""

  read -rp "Also clone extra repositories (game engine, SPADS source, infra)? [y/N] " extras
  if [[ "$extras" =~ ^[Yy]$ ]]; then
    cmd_clone extra
    echo ""
  fi

  step "3/5  Building Docker images"
  echo ""
  cmd_build
  echo ""

  local do_build_engine=0
  if [ -d "$SCRIPT_DIR/RecoilEngine/docker-build-v2" ]; then
    step "4/5  Engine build"
    echo ""
    read -rp "Build engine from source? [y/N] " build_engine
    if [[ "$build_engine" =~ ^[Yy]$ ]]; then
      do_build_engine=1
      info "Building Recoil engine (this may take a while)..."
      "$SCRIPT_DIR/RecoilEngine/docker-build-v2/build.sh" linux
    fi
    echo ""
  else
    step "4/5  Engine build"
    echo ""
    info "RecoilEngine not cloned -- skipping. Clone with: ./devtools.sh clone extra"
    echo ""
  fi

  step "5/5  Symlinks to game directory"
  echo ""
  local game_dir
  game_dir="$(detect_game_dir 2>/dev/null)" || true
  if [ -z "$game_dir" ]; then
    info "No game directory detected. Set BAR_GAME_DIR to enable linking."
    echo ""
  else
    local available=()
    if [ -d "$SCRIPT_DIR/RecoilEngine" ]; then
      available+=("engine")
    fi
    if [ -d "$SCRIPT_DIR/BYAR-Chobby" ]; then
      available+=("chobby")
    fi
    if [ -d "$SCRIPT_DIR/Beyond-All-Reason" ]; then
      available+=("bar")
    fi

    if [ "${#available[@]}" -gt 0 ]; then
      echo "  Available repos to symlink into $game_dir:"
      for name in "${available[@]}"; do
        case "$name" in
          engine) echo -e "    ${BOLD}engine${NC}  -> $game_dir/engine/local-build/" ;;
          chobby) echo -e "    ${BOLD}chobby${NC}  -> $game_dir/games/BYAR-Chobby/" ;;
          bar)    echo -e "    ${BOLD}bar${NC}     -> $game_dir/games/Beyond-All-Reason/" ;;
        esac
      done
      echo ""
      warn "This will replace any existing directories at these paths with symlinks."
      read -rp "Symlink all? [y/N] " do_link
      if [[ "$do_link" =~ ^[Yy]$ ]]; then
        BAR_GAME_DIR="$game_dir"
        for name in "${available[@]}"; do
          cmd_link "$name"
        done
      fi
    else
      info "No linkable repos cloned yet."
    fi
  fi
  echo ""

  echo -e "${BOLD}=== Setup Complete ===${NC}"
  echo ""
  echo "  Your workspace is ready. Next steps:"
  echo ""
  echo -e "    ${BOLD}./devtools.sh up${NC}             Start Teiserver + PostgreSQL"
  echo -e "    ${BOLD}./devtools.sh up lobby${NC}       ...and launch bar-lobby"
  echo -e "    ${BOLD}./devtools.sh up spads${NC}       ...and start SPADS autohost"
  echo -e "    ${BOLD}./devtools.sh engine build${NC}   Build the Recoil engine"
  echo -e "    ${BOLD}./devtools.sh link${NC}           Show symlink status"
  echo -e "    ${BOLD}./devtools.sh repos${NC}          Show repository status"
  echo ""
  echo "  To use your own forks, copy repos.conf to repos.local.conf"
  echo "  and edit the URLs/branches. Then run: ./devtools.sh clone"
  echo ""
}

cmd_setup() {
  echo -e "${BOLD}=== BAR Dev Environment Setup ===${NC}"
  echo ""
  check_prerequisites || exit 1

  local missing_core=0
  load_repos_conf
  for i in "${!REPO_DIRS[@]}"; do
    if [ "${REPO_GROUPS[$i]}" = "core" ] && [ ! -d "$SCRIPT_DIR/${REPO_DIRS[$i]}/.git" ]; then
      missing_core=1
      break
    fi
  done

  if [ "$missing_core" -eq 1 ]; then
    warn "Core repositories are missing. Cloning them now..."
    echo ""
    cmd_clone core
    echo ""
  fi

  cmd_build

  echo ""
  echo -e "  Next steps:"
  echo -e "    ${BOLD}./devtools.sh up${NC}       Start all services"
  echo -e "    ${BOLD}./devtools.sh up lobby${NC} Start all services + bar-lobby"
  echo ""
}

cmd_up() {
  local start_lobby=0
  local with_spads=0
  for arg in "$@"; do
    case "$arg" in
      lobby|--lobby) start_lobby=1 ;;
      spads|--spads) with_spads=1 ;;
    esac
  done

  install_dockerignore

  if [ "$with_spads" -eq 1 ]; then
    info "Starting PostgreSQL, Teiserver, and SPADS..."
    $COMPOSE --profile spads up -d --build
  else
    info "Starting PostgreSQL and Teiserver..."
    $COMPOSE up -d --build
  fi

  echo ""
  info "Waiting for Teiserver to become healthy (first run takes several minutes)..."
  echo "  Follow progress: ./devtools.sh logs teiserver"
  echo ""

  local attempts=0
  local max_attempts=120
  while [ $attempts -lt $max_attempts ]; do
    local health
    health=$($COMPOSE ps teiserver --format '{{.Health}}' 2>/dev/null || echo "unknown")
    case "$health" in
      healthy)
        ok "Teiserver is healthy!"
        break
        ;;
      unhealthy)
        err "Teiserver failed to start. Check logs: ./devtools.sh logs teiserver"
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
    err "Timed out waiting for Teiserver. Check logs: ./devtools.sh logs teiserver"
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
    echo -e "  SPADS is starting (check: ./devtools.sh logs spads)"
  fi
  echo ""

  if [ "$start_lobby" -eq 1 ]; then
    cmd_lobby
  fi
}

cmd_down() {
  info "Stopping all services..."
  $COMPOSE --profile spads down
  ok "All services stopped."
}

cmd_status() {
  echo -e "${BOLD}=== Service Status ===${NC}"
  echo ""
  $COMPOSE --profile spads ps -a
}

cmd_logs() {
  local service="${1:-}"
  if [ -z "$service" ]; then
    $COMPOSE --profile spads logs -f --tail=100
  else
    $COMPOSE --profile spads logs -f --tail=100 "$service"
  fi
}

cmd_lobby() {
  if [ ! -d "$LOBBY_DIR" ]; then
    err "bar-lobby directory not found at: $LOBBY_DIR"
    err "Run './devtools.sh clone' to clone repositories first."
    exit 1
  fi

  if ! command -v node &>/dev/null; then
    err "Node.js is required for bar-lobby. Run './devtools.sh install-deps'."
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
}

cmd_reset() {
  echo -e "${YELLOW}${BOLD}This will destroy all data (database, SPADS state, engine cache).${NC}"
  read -rp "Are you sure? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi

  info "Stopping services and removing volumes..."
  $COMPOSE --profile spads down -v

  info "Rebuilding images from scratch..."
  $COMPOSE build --no-cache teiserver
  $COMPOSE --profile spads pull spads

  ok "Reset complete. Run './devtools.sh up' to start fresh."
}

cmd_shell() {
  local service="${1:-teiserver}"
  info "Opening shell in ${service}..."
  $COMPOSE --profile spads exec "$service" bash
}

cmd_update() {
  echo -e "${BOLD}=== Updating All Repositories ===${NC}"
  echo ""
  load_repos_conf

  local i
  for i in "${!REPO_DIRS[@]}"; do
    local dir="${REPO_DIRS[$i]}"
    local target="$SCRIPT_DIR/$dir"
    if [ -d "$target/.git" ]; then
      local branch
      branch="$(git -C "$target" branch --show-current 2>/dev/null)"
      info "${dir}: pulling ${branch}..."
      git -C "$target" pull --ff-only 2>&1 | sed 's/^/    /' || warn "  ${dir}: pull failed (conflicts?)"
    fi
  done
  echo ""
  ok "Update complete."
}

# ===========================================================================
# Help
# ===========================================================================

show_help() {
  echo -e "${BOLD}BAR Development Environment${NC}"
  echo ""
  echo "Usage: ./devtools.sh <command> [args]"
  echo ""
  echo -e "${BOLD}Getting Started (new developer):${NC}"
  echo "  init             Full first-time setup: install deps, clone repos, build images"
  echo "  install-deps     Install system packages (docker, git, nodejs)"
  echo ""
  echo -e "${BOLD}Services:${NC}"
  echo "  setup            Check prerequisites and build Docker images"
  echo "  up [options]     Start services. Options: lobby, spads"
  echo "  down             Stop all services"
  echo "  status           Show running services"
  echo "  logs [service]   Tail logs (postgres, teiserver, spads, or all)"
  echo "  lobby            Start bar-lobby dev server"
  echo "  reset            Destroy all data and rebuild from scratch"
  echo "  shell [svc]      Open a shell in a container (default: teiserver)"
  echo ""
  echo -e "${BOLD}Engine:${NC}"
  echo "  engine build [args]   Build Recoil engine via docker-build-v2"
  echo ""
  echo -e "${BOLD}Game Directory:${NC}"
  echo "  link [target]    Symlink repos into game directory (engine, chobby, bar)"
  echo "                   With no target, shows status of all links"
  echo ""
  echo -e "${BOLD}Repositories:${NC}"
  echo "  clone [group]    Clone/update repos (group: core, extra, or all)"
  echo "  repos            Show status of all configured repositories"
  echo "  update           Pull latest on all cloned repositories"
  echo ""
  echo -e "${BOLD}Examples:${NC}"
  echo "  ./devtools.sh init               # New developer? Start here"
  echo "  ./devtools.sh up                 # Start postgres + teiserver"
  echo "  ./devtools.sh up lobby           # Start stack + bar-lobby"
  echo "  ./devtools.sh up spads lobby     # Start everything"
  echo "  ./devtools.sh engine build linux # Build engine for linux"
  echo "  ./devtools.sh link               # Show symlink status"
  echo "  ./devtools.sh link engine        # Symlink engine to game dir"
  echo "  ./devtools.sh repos              # Check repo status"
  echo "  ./devtools.sh clone extra        # Clone optional repos"
  echo "  ./devtools.sh logs teiserver     # Follow Teiserver logs"
  echo ""
  echo -e "${BOLD}Configuration:${NC}"
  echo "  repos.conf         Default repository URLs and branches"
  echo "  repos.local.conf   Personal overrides (forks, branches) -- gitignored"
  echo "  BAR_GAME_DIR       Env var: path to BAR game data directory (auto-detected if unset)"
  echo ""
  echo "  To use your own fork of teiserver:"
  echo "    cp repos.conf repos.local.conf"
  echo "    # Edit repos.local.conf: change teiserver URL to your fork"
  echo "    ./devtools.sh clone core"
  echo ""
  echo -e "${BOLD}Docker Services:${NC}"
  echo "  postgres    PostgreSQL 16 database"
  echo "  teiserver   Elixir lobby server (HTTP :4000, Spring :8200/:8201)"
  echo "  spads       Perl autohost (optional, needs game data)"
  echo "  bar-lobby   Electron game client (runs natively, not in Docker)"
  echo ""
}

# ===========================================================================
# Dispatch
# ===========================================================================

case "${1:-help}" in
  init)         cmd_init ;;
  install-deps) cmd_install_deps ;;
  setup)        cmd_setup ;;
  up)           shift; cmd_up "$@" ;;
  down)         cmd_down ;;
  status)       cmd_status ;;
  logs)         cmd_logs "${2:-}" ;;
  lobby)        cmd_lobby ;;
  reset)        cmd_reset ;;
  shell)        cmd_shell "${2:-teiserver}" ;;
  clone)        cmd_clone "${2:-all}" ;;
  repos)        cmd_repos ;;
  update)       cmd_update ;;
  build)        cmd_build ;;
  engine)       shift; cmd_engine "$@" ;;
  link)         cmd_link "${2:-}" ;;
  help|--help|-h) show_help ;;
  *)            err "Unknown command: $1"; echo ""; show_help; exit 1 ;;
esac
