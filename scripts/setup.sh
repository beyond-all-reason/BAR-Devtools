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

is_wsl() {
  [ -n "${WSL_DISTRO_NAME:-}" ] || [ -f /proc/sys/fs/binfmt_misc/WSLInterop ]
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
    arch:docker)           echo "docker docker-buildx" ;;
    arch:docker-compose)   echo "docker-compose" ;;
    arch:git)              echo "git" ;;
    arch:distrobox)        echo "distrobox" ;;
    debian:docker)         echo "docker-ce docker-ce-cli containerd.io docker-buildx-plugin" ;;
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
    echo "  Add yourself:       sudo usermod -aG docker \$USER"
    if grep -qi microsoft /proc/version 2>/dev/null; then
      echo "  Then on WSL2:       wsl --shutdown  (from Windows PowerShell), reopen WSL"
    else
      echo "  Then re-login (log out of your desktop session and back in)"
    fi
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

# Idempotent WSL2 environment prep: enable systemd, mark / as a shared mount.
# Required for docker-backed distrobox to work. No-op outside WSL2.
ensure_wsl_setup() {
  grep -qi microsoft /proc/version 2>/dev/null || return 0

  echo -e "${BOLD}=== WSL2 environment prep ===${NC}"
  echo ""

  local wsl_conf="/etc/wsl.conf"
  local needs_shutdown=0

  [ -f "$wsl_conf" ] || sudo touch "$wsl_conf"

  if ! sudo grep -qE '^\[boot\]' "$wsl_conf"; then
    info "Adding [boot] section to $wsl_conf"
    echo -e "\n[boot]" | sudo tee -a "$wsl_conf" >/dev/null
  fi

  if ! sudo grep -qE '^\s*systemd\s*=\s*true' "$wsl_conf"; then
    if sudo grep -qE '^\s*systemd\s*=' "$wsl_conf"; then
      warn "$wsl_conf has 'systemd=' set to a non-true value -- leaving it alone."
      warn "  BAR-Devtools' docker path needs systemd; flip it manually if that's a mistake."
    else
      info "Enabling systemd in $wsl_conf"
      sudo sed -i '/^\[boot\]/a systemd=true' "$wsl_conf"
      needs_shutdown=1
    fi
  fi

  if ! sudo grep -qE '^\s*command\s*=.*make-rshared' "$wsl_conf"; then
    info "Persisting 'mount --make-rshared /' in $wsl_conf (rebind / as shared mount on every boot)"
    sudo sed -i '/^\[boot\]/a command="mount --make-rshared /"' "$wsl_conf"
  fi

  # If systemd isn't PID 1, the user must restart WSL before we can proceed.
  if [ "$(ps -p 1 -o comm= 2>/dev/null)" != "systemd" ] || [ "$needs_shutdown" -eq 1 ]; then
    echo ""
    warn "WSL must restart to pick up systemd."
    warn "  From Windows PowerShell:  wsl --shutdown"
    warn "  Then reopen WSL and re-run: just setup::init"
    exit 0
  fi

  # systemd is up; ensure / is shared right now (avoids forcing a shutdown just for this).
  local rootprop
  rootprop="$(findmnt -no PROPAGATION / 2>/dev/null || echo unknown)"
  if [ "$rootprop" != "shared" ]; then
    info "Re-mounting / as shared (one-shot for current boot; persisted via wsl.conf above)"
    sudo mount --make-rshared /
    rootprop="$(findmnt -no PROPAGATION /)"
    if [ "$rootprop" != "shared" ]; then
      err "Failed to mark / as shared (got '$rootprop'). Cannot proceed."
      exit 1
    fi
  fi

  ok "WSL2 environment ready (systemd active, / is a shared mount)"
  echo ""
}

# True if $1 looks like a real Windows Python (not the Microsoft Store
# placeholder under WindowsApps that opens the Store when invoked).
_is_real_windows_python() {
  local p="$1"
  [ -n "$p" ] || return 1
  # Reject the Store stub and the WindowsApps reparse-point path.
  case "$p" in
    *WindowsApps*python.exe|*WindowsApps*py.exe) return 1 ;;
  esac
  return 0
}

# Install Python on the Windows host via winget. Phase 3 of the bar::launch
# sync pipeline (and the probe_wsl_sync.py helper) need py.exe / python.exe on
# Windows. Idempotent: skips if a real Python is already on the Windows PATH,
# and is a no-op outside WSL.
ensure_windows_python() {
  is_wsl || return 0

  local py_path python_path
  py_path="$(command -v py.exe 2>/dev/null || true)"
  python_path="$(command -v python.exe 2>/dev/null || true)"

  if _is_real_windows_python "$py_path"; then
    ok "Windows Python already installed: $py_path"
    return 0
  fi
  if _is_real_windows_python "$python_path"; then
    ok "Windows Python already installed: $python_path"
    return 0
  fi

  if [ -n "$python_path" ]; then
    info "Detected Microsoft Store python.exe stub at $python_path -- not a real install."
  fi

  if ! command -v winget.exe &>/dev/null; then
    warn "winget.exe not found on the Windows PATH -- can't auto-install Python."
    warn "Install manually from https://www.python.org/downloads/ and re-open the WSL shell."
    return 0
  fi

  echo ""
  info "Phase 3 sync watcher and probe_wsl_sync.py both need py.exe / python.exe on Windows."
  read -rp "Install Python 3.12 via winget on Windows now? [Y/n] " ans
  if [[ "$ans" =~ ^[Nn]$ ]]; then
    info "Skipped. Run later: winget install Python.Python.3.12"
    return 0
  fi

  step "Installing Python 3.12 on Windows via winget..."
  winget.exe install Python.Python.3.12 \
    --silent \
    --accept-source-agreements \
    --accept-package-agreements \
    || warn "winget exited non-zero. Check the output above; Python may still be installed."

  hash -r
  py_path="$(command -v py.exe 2>/dev/null || true)"
  python_path="$(command -v python.exe 2>/dev/null || true)"
  if _is_real_windows_python "$py_path" || _is_real_windows_python "$python_path"; then
    ok "Windows Python installed."
  else
    warn "winget finished but a real py.exe / python.exe still isn't on PATH."
    warn "Open a new WSL shell (Windows PATH is re-imported at WSL shell start)."
    warn "If it still isn't visible, check: winget list Python.Python.3.12 (from cmd/PowerShell)."
  fi
}

# Set up Docker's official apt repository (Debian/Ubuntu).
# Idempotent: returns early if the keyring + sources file are already in place.
setup_docker_repo_debian() {
  if [ -f /etc/apt/keyrings/docker.asc ] && [ -f /etc/apt/sources.list.d/docker.list ]; then
    return 0
  fi
  info "Adding Docker's official apt repository (apt's docker.io lags upstream)..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  local arch codename
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-noble}}")"
  echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  ok "Docker apt repository configured"
}

# If Ubuntu's apt-shipped 'docker.io' is installed, offer to replace with docker-ce stack.
# Returns 0 whether or not migration happened (caller continues either way).
migrate_docker_io_debian() {
  if ! dpkg -l docker.io 2>/dev/null | grep -q '^ii'; then
    return 0
  fi
  warn "Detected apt's 'docker.io' package -- it lags upstream Docker CE."
  echo "  To get the modern Docker stack we'd purge docker.io / docker-buildx /"
  echo "  docker-compose-v2 and replace with docker-ce + plugins from Docker's repo."
  read -rp "Replace docker.io with docker-ce? [Y/n] " ans
  if [[ "$ans" =~ ^[Nn]$ ]]; then
    info "Keeping apt's docker.io. Skipping docker-ce upgrade."
    return 0
  fi
  info "Stopping docker daemon and purging apt's docker.io / docker-buildx / docker-compose-v2..."
  sudo systemctl stop docker.socket docker.service 2>/dev/null || true
  sudo apt-get purge -y docker.io docker-buildx docker-compose-v2 2>/dev/null || true
  sudo apt-get autoremove -y -qq 2>/dev/null || true
}

# Install distrobox from upstream main. Apt's distrobox on Ubuntu LTS (1.7.0)
# predates PR #1965 (merged 2026-01-17, first in tag 1.8.2.3) which dropped the
# 'chpasswd -e' usage that fails against shadow-utils 4.13+'s hash validation.
# Idempotent: skips only if /usr/local/bin/distrobox is >= 1.8.2.3.
install_distrobox_upstream() {
  local current
  current="$(/usr/local/bin/distrobox --version 2>/dev/null | awk '{print $NF}')"
  if [ -n "$current" ] && _distrobox_ver_ge "$current" "1.8.2.3"; then
    ok "distrobox already up-to-date at /usr/local/bin: $current"
    return 0
  fi
  info "Installing distrobox from upstream (need >= 1.8.2.3 for the chpasswd-hash-validation fix)..."
  sudo apt-get purge -y distrobox 2>/dev/null || true
  curl -fsSL https://raw.githubusercontent.com/89luca89/distrobox/main/install \
    | sudo sh -s -- --prefix /usr/local
  hash -r
  ok "distrobox installed: $(/usr/local/bin/distrobox --version 2>/dev/null | awk '{print $NF}')"
}

# Pure-bash version comparison: returns 0 if $1 >= $2, else 1.
_distrobox_ver_ge() {
  local IFS=.
  local -a a=($1) b=($2)
  local i max=${#a[@]}
  [ "${#b[@]}" -gt "$max" ] && max=${#b[@]}
  for ((i=0; i<max; i++)); do
    local ai=${a[i]:-0} bi=${b[i]:-0}
    if (( 10#$ai > 10#$bi )); then return 0; fi
    if (( 10#$ai < 10#$bi )); then return 1; fi
  done
  return 0
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

  # Debian-specific: switch from apt's stale docker.io to Docker CE before detecting deps.
  if [ "$distro" = "debian" ]; then
    setup_docker_repo_debian
    migrate_docker_io_debian
  fi

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

  # On Debian, distrobox is always installed from upstream (apt's version is broken
  # against shadow-utils 4.13+). Drop it from the apt list.
  local apt_missing=()
  for tool in "${missing[@]}"; do
    if [ "$distro" = "debian" ] && [ "$tool" = "distrobox" ]; then continue; fi
    apt_missing+=("$tool")
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    ok "All package-manager dependencies already installed."
    echo ""

    # Even when nothing was missing, ensure distrobox on Debian is the upstream version.
    [ "$distro" = "debian" ] && install_distrobox_upstream

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

  if [ "${#apt_missing[@]}" -gt 0 ]; then
    local packages=""
    for dep in "${apt_missing[@]}"; do
      packages+=" $(pkg_name "$dep")"
    done

    info "Missing (via package manager): ${apt_missing[*]}"
    info "Will run: ${install_cmd}${packages}"
    echo ""

    read -rp "Install now? [Y/n] " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
      echo "Skipped. Install manually and retry."
      return 1
    fi

    $install_cmd $packages
    echo ""
  fi

  # Always run after apt step on Debian -- handles both "distrobox missing" and
  # "apt's distrobox installed but too old."
  if [ "$distro" = "debian" ]; then
    install_distrobox_upstream
    echo ""
  fi

  if [[ " ${missing[*]} " == *" docker "* ]]; then
    info "Enabling and starting Docker daemon..."
    sudo systemctl enable --now docker 2>/dev/null || true

    if ! groups | grep -qw docker; then
      info "Adding $USER to the docker group..."
      sudo usermod -aG docker "$USER"
      echo ""
      warn "Docker group membership only takes effect in a fresh shell."
      if grep -qi microsoft /proc/version 2>/dev/null; then
        warn "  On WSL2: from Windows PowerShell, run:  wsl --shutdown"
        warn "  Then reopen your WSL terminal (closing the tab is NOT enough --"
        warn "  the WSL2 distro keeps running headless until you shut it down)."
      else
        warn "  On Linux desktop: log out of your session and log back in."
      fi
      warn "After that, re-run: just setup::init"
      exit 0
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

  ensure_wsl_setup

  local runtime="podman"
  command -v podman &>/dev/null || runtime="docker"

  step "Building dev container image ($DEV_IMAGE)..."
  $runtime build -t "$DEV_IMAGE" -f "$DEVTOOLS_DIR/docker/dev.Containerfile" "$DEVTOOLS_DIR"
  ok "Image built: $DEV_IMAGE"
  echo ""

  if distrobox list 2>/dev/null | grep -q "$DEV_BOX" || $runtime ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DEV_BOX"; then
    warn "Distrobox '$DEV_BOX' already exists. Recreating..."
    distrobox stop "$DEV_BOX" 2>/dev/null || true
    distrobox rm -f "$DEV_BOX" 2>/dev/null \
      || $runtime rm -f "$DEV_BOX" 2>/dev/null \
      || true
  fi

  step "Creating distrobox '$DEV_BOX'..."
  local image_ref="$DEV_IMAGE"
  [ "$runtime" = "podman" ] && image_ref="localhost/$DEV_IMAGE"
  distrobox create --name "$DEV_BOX" --image "$image_ref" --yes
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

# Feature -> repo dirs it pulls in.
feature_repos() {
  case "$1" in
    bar)          echo "Beyond-All-Reason bar-lobby" ;;
    recoil)       echo "RecoilEngine" ;;
    teiserver)    echo "teiserver spads_config_bar" ;;
    chobby)       echo "BYAR-Chobby bar-lobby" ;;
    spads-source) echo "SPADS SpringLobbyInterface ansible-spads-setup" ;;
    *)            echo "" ;;
  esac
}

# True if the comma-separated feature list contains $2.
features_include() {
  local IFS=','
  local f
  for f in $1; do
    [ "$f" = "$2" ] && return 0
  done
  return 1
}

# Comma-separated features -> deduplicated space-separated repo dirs.
features_to_repos() {
  local IFS=','
  local f r
  declare -A seen=()
  for f in $1; do
    for r in $(feature_repos "$f"); do
      seen[$r]=1
    done
  done
  echo "${!seen[@]}"
}

# Interactive checkbox list. Args after the title are "key|label|default" where
# default is 1 (checked) or 0 (unchecked). On confirm, sets CHECKBOX_RESULT to
# the comma-separated keys of the selected items. Returns 1 on quit.
checkbox_list() {
  local title="$1"; shift
  local -a keys=() labels=() state=()
  local item
  for item in "$@"; do
    keys+=("${item%%|*}")
    local rest="${item#*|}"
    labels+=("${rest%|*}")
    state+=("${rest##*|}")
  done
  local n=${#keys[@]}
  local first=1

  trap 'stty echo 2>/dev/null' EXIT
  stty -echo 2>/dev/null

  local i mark
  while true; do
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf '\e[%dA' $((n + 4))
    fi
    printf '\e[J'

    echo -e "${BOLD}${title}${NC}"
    echo -e "  ${DIM}1-${n} toggle - a all - n none - enter confirm${NC}"
    echo ""
    for ((i=0; i<n; i++)); do
      [ "${state[i]}" = "1" ] && mark="[${GREEN}x${NC}]" || mark="[ ]"
      echo -e "  ${DIM}$((i + 1)).${NC} ${mark} ${labels[i]}"
    done
    echo ""

    local key=""
    IFS= read -rsn1 key
    case "$key" in
      [1-9])
        local idx=$((key - 1))
        if [ "$idx" -lt "$n" ]; then
          state[idx]=$(( 1 - ${state[idx]:-0} ))
        fi
        ;;
      a|A)       for ((i=0; i<n; i++)); do state[i]=1; done ;;
      n|N)       for ((i=0; i<n; i++)); do state[i]=0; done ;;
      ''|$'\n')  break ;;
      q|Q)       stty echo 2>/dev/null; trap - EXIT; return 1 ;;
    esac
  done
  stty echo 2>/dev/null
  trap - EXIT

  local picked=()
  for ((i=0; i<n; i++)); do
    [ "${state[i]}" = "1" ] && picked+=("${keys[i]}")
  done
  CHECKBOX_RESULT="$(IFS=,; echo "${picked[*]}")"
  return 0
}

# Single-list checkbox picker for components. Sets BAR_FEATURES_SELECTED.
pick_features() {
  CHECKBOX_RESULT=""
  if ! checkbox_list "Which BAR components will you work on?" \
    "bar|BAR game content + bar-lobby client|1" \
    "recoil|Recoil engine (build from source)|1" \
    "teiserver|Teiserver (lobby/matchmaking server)|1" \
    "chobby|Chobby (in-game lobby)|1" \
    "spads-source|SPADS source (autohost dev, optional)|0"
  then
    BAR_FEATURES_SELECTED=""
    warn "Selection cancelled."
    return
  fi

  if [ -z "$CHECKBOX_RESULT" ]; then
    BAR_FEATURES_SELECTED=""
    warn "No features selected. Nothing to clone or build."
    return
  fi

  BAR_FEATURES_SELECTED="$CHECKBOX_RESULT"
  ok "Selected: ${BAR_FEATURES_SELECTED}"
}

# Persist BAR_FEATURES=... to .env (overwrite if already set).
write_features_env() {
  local features="$1"
  local env_file="$DEVTOOLS_DIR/.env"
  touch "$env_file"
  if grep -q "^BAR_FEATURES=" "$env_file"; then
    sed -i "s|^BAR_FEATURES=.*|BAR_FEATURES=${features}|" "$env_file"
    info "Updated BAR_FEATURES in .env: ${features}"
  else
    echo "BAR_FEATURES=${features}" >> "$env_file"
    ok "Added BAR_FEATURES=${features} to .env"
  fi
}

# Clone only the repos that map to the selected features.
clone_for_features() {
  local features="$1"
  if [ -z "$features" ]; then
    return 0
  fi
  local wanted
  wanted="$(features_to_repos "$features")"

  load_repos_conf

  echo -e "${BOLD}=== Cloning repositories for: ${features} ===${NC}"
  echo ""

  if [ -f "$REPOS_LOCAL" ]; then
    info "Using overrides from repos.local.conf"
    echo ""
  fi

  local i cloned=0 updated=0 linked=0
  for i in "${!REPO_DIRS[@]}"; do
    local dir="${REPO_DIRS[$i]}"
    [[ " $wanted " == *" $dir "* ]] || continue

    local local_path="${REPO_LOCAL_PATHS[$i]}"
    if [ -n "$local_path" ]; then
      clone_or_update_repo "$dir" "${REPO_URLS[$i]}" "${REPO_BRANCHES[$i]}" "$local_path"
      linked=$((linked + 1))
    elif [ -d "$DEVTOOLS_DIR/$dir/.git" ]; then
      clone_or_update_repo "$dir" "${REPO_URLS[$i]}" "${REPO_BRANCHES[$i]}"
      updated=$((updated + 1))
    else
      clone_or_update_repo "$dir" "${REPO_URLS[$i]}" "${REPO_BRANCHES[$i]}"
      cloned=$((cloned + 1))
    fi
  done

  echo ""
  local summary="${cloned} cloned, ${updated} updated"
  [ "$linked" -gt 0 ] && summary+=", ${linked} linked"
  ok "Repos: ${summary}"
}

cmd_init() {
  echo -e "${BOLD}==========================================${NC}"
  echo -e "${BOLD}  BAR Dev Environment - First Time Setup${NC}"
  echo -e "${BOLD}==========================================${NC}"
  echo ""

  ensure_wsl_setup

  step "1/6  Checking & installing dependencies"
  echo ""
  if check_git &>/dev/null && check_docker &>/dev/null; then
    ok "Core dependencies (git, docker) already installed."
  else
    cmd_install_deps || { err "Dependency installation failed. Fix and retry."; exit 1; }
  fi
  ensure_windows_python
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

  step "3/6  Component selection & cloning"
  echo ""
  if [ ! -f "$REPOS_CONF" ]; then
    err "repos.conf not found at: $REPOS_CONF"
    exit 1
  fi

  pick_features
  local features="${BAR_FEATURES_SELECTED:-}"
  if [ -z "$features" ]; then
    info "Skipping clone/build steps. Re-run 'just setup::init' to pick components."
    return 0
  fi
  write_features_env "$features"
  echo ""
  clone_for_features "$features"
  echo ""

  step "4/6  Building Docker images"
  echo ""
  if features_include "$features" teiserver; then
    install_dockerignore
    info "Building Docker images..."
    $COMPOSE build teiserver
    $COMPOSE --profile spads pull spads
    ok "Images built successfully."
  else
    info "Teiserver not selected -- skipping Docker image build."
  fi
  echo ""

  step "5/6  Engine build"
  echo ""
  if features_include "$features" recoil; then
    if [ -d "$DEVTOOLS_DIR/RecoilEngine/docker-build-v2" ]; then
      local engine_arch engine_os="linux"
      case "$(uname -m)" in
        x86_64)        engine_arch="amd64" ;;
        aarch64|arm64) engine_arch="arm64" ;;
        *)             engine_arch="amd64" ;;
      esac
      is_wsl && engine_os="windows"
      info "Building Recoil engine (${engine_arch}-${engine_os}, this may take a while)..."
      bash "$DEVTOOLS_DIR/RecoilEngine/docker-build-v2/build.sh" --arch "$engine_arch" "$engine_os"
    else
      warn "Recoil selected but RecoilEngine/docker-build-v2 missing -- clone may have failed."
    fi
  else
    info "Recoil not selected -- skipping engine build."
  fi
  echo ""

  step "6/6  Symlinks to game directory"
  echo ""
  local game_dir
  game_dir="$(detect_game_dir 2>/dev/null)" || true
  if [ -z "$game_dir" ]; then
    info "No game directory detected. Set BAR_GAME_DIR to enable linking."
  else
    local available=()
    features_include "$features" recoil && [ -d "$DEVTOOLS_DIR/RecoilEngine" ] && available+=("engine")
    features_include "$features" chobby && [ -d "$DEVTOOLS_DIR/BYAR-Chobby" ]    && available+=("chobby")
    features_include "$features" bar    && [ -d "$DEVTOOLS_DIR/Beyond-All-Reason" ] && available+=("bar")

    if [ "${#available[@]}" -gt 0 ]; then
      echo "  Repos to symlink into $game_dir:"
      local name
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
      info "No linkable repos for the selected features."
    fi
  fi
  echo ""

  echo -e "${BOLD}=== Setup Complete ===${NC}"
  echo ""
  echo "  Selected features: ${features}"
  echo ""
  echo "  Your workspace is ready. Next steps:"
  echo ""
  if features_include "$features" teiserver; then
    echo -e "  ${CYAN}Teiserver${NC}"
    echo -e "    ${BOLD}just services::up${NC}             Start Teiserver + PostgreSQL"
    echo -e "    ${BOLD}just services::up spads${NC}       ...and start SPADS autohost"
    echo ""
  fi
  if features_include "$features" bar; then
    echo -e "  ${CYAN}BAR (game content)${NC}"
    echo -e "    ${BOLD}just services::up lobby${NC}       Launch bar-lobby and connect"
    echo -e "    ${BOLD}just bar::units${NC}               Run busted Lua unit tests"
    echo -e "    ${BOLD}just bar::test-shell${NC}          Drop into an interactive busted shell"
    echo -e "    ${BOLD}just bar::check${NC}               LuaLS type-check across the repo"
    echo -e "    ${BOLD}just bar::lint${NC}                luacheck (via lux)"
    echo -e "    ${BOLD}just bar::fmt${NC}                 stylua format"
    echo -e "    ${BOLD}just bar::integrations${NC}        Headless integration tests (x86-64 only)"
    echo -e "    ${BOLD}just bar::setup-hooks${NC}         Install the stylua pre-commit hook"
    echo -e "    ${DIM}Edits land in Beyond-All-Reason/ and reflect live via the symlink.${NC}"
    echo ""
  fi
  if features_include "$features" chobby && ! features_include "$features" bar; then
    echo -e "  ${CYAN}Chobby${NC}"
    echo -e "    ${BOLD}just services::up lobby${NC}       Launch bar-lobby (loads BYAR-Chobby)"
    echo ""
  fi
  if features_include "$features" recoil; then
    echo -e "  ${CYAN}Recoil${NC}"
    if is_wsl; then
      echo -e "    ${BOLD}just engine::build windows${NC}    Rebuild the engine"
    else
      echo -e "    ${BOLD}just engine::build linux${NC}      Rebuild the engine"
    fi
    echo ""
  fi
  if features_include "$features" spads-source; then
    echo -e "  ${CYAN}SPADS source${NC}"
    echo -e "    ${DIM}see SPADS/ and SpringLobbyInterface/ for autohost dev${NC}"
    echo ""
  fi
  echo -e "  ${CYAN}Workspace${NC}"
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
  if is_wsl && command -v wslpath &>/dev/null && command -v cmd.exe &>/dev/null; then
    local win_userprofile
    win_userprofile="$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r\n')"
    if [ -n "$win_userprofile" ]; then
      candidate="$(wslpath "$win_userprofile")/AppData/Local/Programs/Beyond-All-Reason/data"
      if [ -d "$candidate" ]; then
        echo "$candidate"
        return 0
      fi
    fi
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
      local engine_arch engine_os="linux"
      case "$(uname -m)" in
        x86_64)        engine_arch="amd64" ;;
        aarch64|arm64) engine_arch="arm64" ;;
        *)             engine_arch="amd64" ;;
      esac
      is_wsl && engine_os="windows"
      source_path="$DEVTOOLS_DIR/RecoilEngine/build-${engine_arch}-${engine_os}/install"
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
      if is_wsl; then
        echo "  Build the engine first: just engine::build windows"
      else
        echo "  Build the engine first: just engine::build linux"
      fi
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
