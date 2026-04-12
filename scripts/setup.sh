#!/usr/bin/env bash
# Setup, dependency installation, and prerequisite checks.
# Expects: DEVTOOLS_DIR, COMPOSE, REPOS_CONF (exported by Justfile)
# Source scripts/common.sh and scripts/repos.sh before this file.

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

pkg_name() {
  local generic="$1"
  local distro
  distro="$(detect_distro)"
  case "${distro}:${generic}" in
    arch:docker)           echo "docker" ;;
    arch:docker-compose)   echo "docker-compose" ;;
    arch:git)              echo "git" ;;
    arch:distrobox)        echo "distrobox" ;;
    debian:docker)         echo "docker.io" ;;
    debian:docker-compose) echo "docker-compose-plugin" ;;
    debian:git)            echo "git" ;;
    debian:distrobox)      echo "distrobox" ;;
    fedora:docker)         echo "docker-ce docker-ce-cli containerd.io" ;;
    fedora:docker-compose) echo "docker-compose-plugin" ;;
    fedora:git)            echo "git" ;;
    fedora:distrobox)      echo "distrobox" ;;
    *)                     echo "$generic" ;;
  esac
}

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

check_distrobox() {
  if ! command -v distrobox &>/dev/null; then
    warn "distrobox not found. Install it for the recommended dev environment."
    warn "See: https://distrobox.it/#installation"
    return 1
  fi
  ok "distrobox $(distrobox version 2>/dev/null | head -1) detected"
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
  check_git       || failed=1
  check_docker    || failed=1
  check_distrobox || true
  check_ports
  echo ""
  if [ "$failed" -ne 0 ]; then
    err "Missing required prerequisites. Run 'just setup::deps' or fix manually."
    return 1
  fi
}

install_dockerignore() {
  local target="$DEVTOOLS_DIR/teiserver/.dockerignore"
  local source="$DEVTOOLS_DIR/docker/teiserver.dockerignore"
  if [ -f "$source" ] && [ ! -f "$target" ]; then
    cp "$source" "$target"
    info "Installed .dockerignore for teiserver build context"
  fi
}

cmd_install_deps() {
  echo -e "${BOLD}=== Install System Dependencies ===${NC}"
  echo ""

  local distro
  distro="$(detect_distro)"
  local install_cmd
  install_cmd="$(pkg_install_cmd)"

  if [ "$distro" = "unknown" ] || [ -z "$install_cmd" ]; then
    err "Unsupported distro. Install these manually: git, docker, docker-compose, distrobox"
    info "See docker/dev.Containerfile for the full list of dev tool dependencies."
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
  if ! command -v distrobox &>/dev/null; then
    missing+=("distrobox")
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
      warn "After re-login, run: just setup::init"
      return 0
    fi
  fi

  ok "Dependencies installed successfully."
}

DEV_IMAGE="bar-dev"
DEV_BOX="bar-dev"

cmd_setup_distrobox() {
  echo -e "${BOLD}=== Distrobox Dev Environment ===${NC}"
  echo ""

  if ! command -v distrobox &>/dev/null; then
    err "distrobox is not installed. Run 'just setup::deps' first."
    exit 1
  fi

  local runtime="podman"
  command -v podman &>/dev/null || runtime="docker"

  step "Building dev container image ($DEV_IMAGE)..."
  $runtime build -t "$DEV_IMAGE" -f "$DEVTOOLS_DIR/docker/dev.Containerfile" "$DEVTOOLS_DIR"
  ok "Image built: $DEV_IMAGE"
  echo ""

  if distrobox list 2>/dev/null | grep -q "$DEV_BOX"; then
    warn "Distrobox '$DEV_BOX' already exists. Recreating..."
    distrobox rm -f "$DEV_BOX"
  fi

  step "Creating distrobox '$DEV_BOX'..."
  distrobox create --name "$DEV_BOX" --image "localhost/$DEV_IMAGE" --yes
  ok "Distrobox created: $DEV_BOX"
  echo ""

  step "Running first-entry setup (lux lua tree)..."
  distrobox enter "$DEV_BOX" -- bash -c '
    lx install-lua 2>/dev/null
    LUA_BIN=$(command -v lua-5.1 2>/dev/null || command -v lua5.1 2>/dev/null)
    if [ -n "$LUA_BIN" ]; then
      LUX_LUA="$HOME/.local/share/lux/tree/5.1/.lua/bin/lua"
      mkdir -p "$(dirname "$LUX_LUA")"
      ln -sf "$LUA_BIN" "$LUX_LUA"
    fi
  '
  ok "Lux lua tree configured"
  echo ""

  local env_file="$DEVTOOLS_DIR/.env"
  if grep -q "^DEVTOOLS_DISTROBOX=" "$env_file" 2>/dev/null; then
    info "DEVTOOLS_DISTROBOX already set in .env"
  else
    echo "DEVTOOLS_DISTROBOX=$DEV_BOX" >> "$env_file"
    ok "Added DEVTOOLS_DISTROBOX=$DEV_BOX to .env"
  fi

  echo ""
  ok "Distrobox dev environment ready."
  echo ""
  echo "  Recipes that need lux/node/cargo will now run inside '$DEV_BOX' automatically."
  echo "  To enter the box manually:  distrobox enter $DEV_BOX"
  echo "  To rebuild after changes:   just setup::distrobox"
}

cmd_init() {
  local clone_extras=0
  for arg in "$@"; do
    case "$arg" in
      extras|all) clone_extras=1 ;;
    esac
  done

  echo -e "${BOLD}==========================================${NC}"
  echo -e "${BOLD}  BAR Dev Environment - First Time Setup${NC}"
  echo -e "${BOLD}==========================================${NC}"
  echo ""

  step "1/6  Checking & installing dependencies"
  echo ""
  local deps_ok=0
  if check_git &>/dev/null && check_docker &>/dev/null; then
    deps_ok=1
    ok "Core dependencies (git, docker) already installed."
  else
    cmd_install_deps || { err "Dependency installation failed. Fix and retry."; exit 1; }
    deps_ok=1
  fi
  echo ""

  step "2/6  Dev environment (distrobox)"
  echo ""
  if [ -n "${DEVTOOLS_DISTROBOX:-}" ]; then
    ok "Distrobox already configured: $DEVTOOLS_DISTROBOX"
  elif command -v distrobox &>/dev/null; then
    read -rp "Set up a distrobox dev environment? (recommended) [Y/n] " setup_box
    if [[ ! "$setup_box" =~ ^[Nn]$ ]]; then
      cmd_setup_distrobox
    fi
  else
    info "distrobox not installed -- skipping dev environment setup."
    info "Install distrobox and run 'just setup::distrobox' later for the full toolchain."
  fi
  echo ""

  step "3/6  Cloning repositories"
  echo ""
  if [ ! -f "$REPOS_CONF" ]; then
    err "repos.conf not found at: $REPOS_CONF"
    exit 1
  fi
  cmd_clone core
  echo ""

  if [ "$clone_extras" -eq 1 ]; then
    cmd_clone extra
    echo ""
  else
    read -rp "Also clone extra repositories (game engine, SPADS source, infra)? [y/N] " extras
    if [[ "$extras" =~ ^[Yy]$ ]]; then
      cmd_clone extra
      echo ""
    fi
  fi

  step "4/6  Building Docker images"
  echo ""
  install_dockerignore
  info "Building Docker images..."
  $COMPOSE build teiserver
  $COMPOSE --profile spads pull spads
  ok "Images built successfully."
  echo ""

  if [ -d "$DEVTOOLS_DIR/RecoilEngine/docker-build-v2" ]; then
    step "5/6  Engine build"
    echo ""
    read -rp "Build engine from source? [y/N] " build_engine
    if [[ "$build_engine" =~ ^[Yy]$ ]]; then
      local engine_arch
      case "$(uname -m)" in
        x86_64)       engine_arch="amd64" ;;
        aarch64|arm64) engine_arch="arm64" ;;
        *)            engine_arch="amd64" ;;
      esac
      info "Building Recoil engine (${engine_arch}-linux, this may take a while)..."
      bash "$DEVTOOLS_DIR/RecoilEngine/docker-build-v2/build.sh" --arch "$engine_arch" linux
    fi
    echo ""
  else
    step "5/6  Engine build"
    echo ""
    info "RecoilEngine not cloned -- skipping. Clone with: just repos::clone extra"
    echo ""
  fi

  step "6/6  Symlinks to game directory"
  echo ""
  local game_dir
  game_dir="$(detect_game_dir 2>/dev/null)" || true
  if [ -z "$game_dir" ]; then
    info "No game directory detected. Set BAR_GAME_DIR to enable linking."
    echo ""
  else
    local available=()
    [ -d "$DEVTOOLS_DIR/RecoilEngine" ] && available+=("engine")
    [ -d "$DEVTOOLS_DIR/BYAR-Chobby" ] && available+=("chobby")
    [ -d "$DEVTOOLS_DIR/Beyond-All-Reason" ] && available+=("bar")

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
  echo -e "    ${BOLD}just services::up${NC}             Start Teiserver + PostgreSQL"
  echo -e "    ${BOLD}just services::up lobby${NC}       ...and launch bar-lobby"
  echo -e "    ${BOLD}just services::up spads${NC}       ...and start SPADS autohost"
  echo -e "    ${BOLD}just engine::build linux${NC}      Build the Recoil engine"
  echo -e "    ${BOLD}just link::status${NC}             Show symlink status"
  echo -e "    ${BOLD}just repos::status${NC}            Show repository status"
  echo ""
  echo "  To use your own forks, copy repos.conf to repos.local.conf"
  echo "  and edit the URLs/branches. Then run: just repos::clone"
  echo ""
}

cmd_setup() {
  echo -e "${BOLD}=== BAR Dev Environment Setup ===${NC}"
  echo ""
  check_prerequisites || exit 1

  local missing_core=0
  load_repos_conf
  for i in "${!REPO_DIRS[@]}"; do
    if [ "${REPO_GROUPS[$i]}" = "core" ] && [ ! -d "$DEVTOOLS_DIR/${REPO_DIRS[$i]}/.git" ]; then
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

  install_dockerignore
  info "Building Docker images..."
  $COMPOSE build teiserver
  $COMPOSE --profile spads pull spads
  ok "Images built successfully."

  echo ""
  echo -e "  Next steps:"
  echo -e "    ${BOLD}just services::up${NC}       Start all services"
  echo -e "    ${BOLD}just services::up lobby${NC} Start all services + bar-lobby"
  echo ""
}

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
      local engine_arch
      case "$(uname -m)" in
        x86_64)        engine_arch="amd64" ;;
        aarch64|arm64) engine_arch="arm64" ;;
        *)             engine_arch="amd64" ;;
      esac
      source_path="$DEVTOOLS_DIR/RecoilEngine/build-${engine_arch}-linux/install"
      link_path="$game_dir/engine/local-build"
      ;;
    chobby)
      source_path="$DEVTOOLS_DIR/BYAR-Chobby"
      link_path="$game_dir/games/BYAR-Chobby"
      ;;
    bar)
      source_path="$DEVTOOLS_DIR/Beyond-All-Reason"
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
      echo "  Build the engine first: just engine::build linux"
    else
      echo "  Clone the repo first: just repos::clone extra"
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
