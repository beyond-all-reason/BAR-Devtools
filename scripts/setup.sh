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

# Pure-bash semver compare: returns 0 iff $1 >= $2. Mirrors scripts/bootstrap.sh
# so cmd_init can reject stale `just` (e.g. apt's 1.21) with a clear pointer.
_version_ge() {
  local IFS=.
  local -a A=($1) B=($2)
  local i av bv
  for i in 0 1 2; do
    av="${A[i]:-0}"; bv="${B[i]:-0}"
    (( av > bv )) && return 0
    (( av < bv )) && return 1
  done
  return 0
}

_check_just_min_version() {
  local need="$1"
  local current
  if ! current="$(just --version 2>/dev/null | awk '{print $2}')" || [ -z "$current" ]; then
    err "Could not read 'just --version'. Did 'just' move off PATH?"
    exit 1
  fi
  if ! _version_ge "$current" "$need"; then
    err "Found just $current, need >= $need."
    err "Likely cause: 'apt install just' (Ubuntu LTS ships 1.21, frozen)."
    err "Fix:"
    err "  bash $DEVTOOLS_DIR/scripts/bootstrap.sh"
    err "  # then open a new shell and re-run 'just setup::init'"
    exit 1
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
    ensure_bar_launch_python_persisted
    return 0
  fi
  if _is_real_windows_python "$python_path"; then
    ok "Windows Python already installed: $python_path"
    ensure_bar_launch_python_persisted
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
  info "The Windows-side cold-copy mirror needs py.exe / python.exe on Windows."
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
    ensure_bar_launch_python_persisted
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
    info "Running: ${install_cmd}${packages}"
    echo ""
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

# Resolve the bar_debug_launcher checkout. repos.local.conf may point it at an
# external path; fall back to the in-tree default.
bar_launch_repo_path() {
  load_repos_conf
  local i
  for i in "${!REPO_DIRS[@]}"; do
    if [ "${REPO_DIRS[$i]}" = "bar_debug_launcher" ]; then
      local local_path="${REPO_LOCAL_PATHS[$i]}"
      if [ -n "$local_path" ] && [ -d "$local_path" ]; then
        echo "$local_path"
        return 0
      fi
      break
    fi
  done
  echo "$DEVTOOLS_DIR/bar_debug_launcher"
}

# True on rpm-ostree / Fedora Atomic / Bazzite / Silverblue. dnf installs
# fail on these; the package layer is read-only at runtime.
_is_ostree() {
  command -v rpm-ostree &>/dev/null && [ -e /run/ostree-booted ]
}

# Install pipx if missing. pipx is the upstream-recommended way to install
# Python CLI tools in their own isolated venvs; we use it instead of hand-
# rolling a venv so bar_debug_launcher's pyproject.toml stays the single
# source of truth for its deps. On atomic distros (rpm-ostree) we can't
# layer packages without a reboot, so bootstrap pipx via `pip install --user`
# instead.
_ensure_pipx() {
  if command -v pipx &>/dev/null; then return 0; fi

  if _is_ostree; then
    info "rpm-ostree system detected -- bootstrapping pipx via 'pip install --user'"
    if ! command -v python3 &>/dev/null; then
      err "python3 not found on PATH"
      return 1
    fi
    # PEP 668 / EXTERNALLY-MANAGED is set on most modern distros' system
    # Pythons, so we pass --break-system-packages. This only affects the
    # user site-packages (~/.local), never the OS-managed Python.
    python3 -m pip install --user --break-system-packages --quiet pipx \
      || { err "pip install --user pipx failed"; return 1; }
    python3 -m pipx ensurepath >/dev/null 2>&1 || true
    # Make pipx visible in this shell without requiring a re-login.
    export PATH="$HOME/.local/bin:$PATH"
    hash -r
    command -v pipx &>/dev/null && return 0
    err "pipx installed to ~/.local/bin but still not on PATH"
    info "Open a new shell, or add ~/.local/bin to PATH"
    return 1
  fi

  local distro install_cmd
  distro="$(detect_distro)"
  case "$distro" in
    arch)   install_cmd="sudo pacman -S --needed python-pipx" ;;
    debian) install_cmd="sudo apt install -y pipx" ;;
    fedora) install_cmd="sudo dnf install -y pipx" ;;
    *)      install_cmd="" ;;
  esac

  if [ -z "$install_cmd" ]; then
    err "pipx is not installed and your distro is unknown. Install pipx manually:"
    info "  https://pipx.pypa.io/stable/installation/"
    return 1
  fi

  info "pipx not found. Installing: $install_cmd"
  $install_cmd || { err "pipx install failed"; return 1; }
  pipx ensurepath >/dev/null 2>&1 || true
  hash -r
  command -v pipx &>/dev/null
}

# Find a Python ≥ 3.10 that can actually `import tkinter`. The launcher's GUI
# imports tkinter at module top, and pyenv installs without tk-devel headers
# silently ship a tkinter package whose _tkinter C extension is missing --
# pipx happily creates a venv against such a Python and the import explodes
# at first launch. We probe candidates explicitly (including absolute paths
# under /usr/bin) so a pyenv shim can't shadow the distro's tkinter-capable
# Python.
_pick_tkinter_python() {
  local cand
  for cand in \
      /usr/bin/python3.13 /usr/bin/python3.12 /usr/bin/python3.11 /usr/bin/python3.10 /usr/bin/python3 \
      python3.13 python3.12 python3.11 python3.10 python3; do
    local resolved
    resolved="$(command -v "$cand" 2>/dev/null)" || continue
    "$resolved" - <<'PY' 2>/dev/null && { echo "$resolved"; return 0; }
import sys
if sys.version_info < (3, 10):
    sys.exit(1)
import tkinter  # noqa: F401  -- imports _tkinter as a side effect
PY
  done
  return 1
}

# Editable-install the launcher with pipx, which reads bar_debug_launcher's
# pyproject.toml for deps and exposes the `bar-launch` entry point on PATH.
# Idempotent: --force re-syncs if a previous install exists.
ensure_bar_launch_installed() {
  local repo_path="$1"
  if [ ! -f "$repo_path/pyproject.toml" ]; then
    err "bar_debug_launcher pyproject.toml missing at $repo_path"
    return 1
  fi

  _ensure_pipx || return 1

  local target_py
  target_py="$(_pick_tkinter_python || true)"
  if [ -z "$target_py" ]; then
    err "No Python ≥ 3.10 with a working tkinter found."
    info "The launcher's GUI imports tkinter; pipx will not auto-fix this."
    info "Fedora:  sudo dnf install python3-tkinter   (or rpm-ostree install)"
    info "Debian:  sudo apt install python3-tk"
    info "Arch:    sudo pacman -S tk"
    info "pyenv:   install tk-devel (Fedora) / tk-dev (Debian) and rebuild Python"
    return 1
  fi

  step "Installing bar_debug_launcher via pipx (editable, --python $target_py)"
  # `pipx install --force --python ...` silently ignores --python when an
  # existing venv is reused, so uninstall first to guarantee the new Python
  # actually sticks. Editable installs are cheap to rebuild.
  pipx uninstall bar-launch >/dev/null 2>&1 || true
  pipx uninstall bar_launch >/dev/null 2>&1 || true
  pipx install --editable --python "$target_py" "$repo_path"

  # Marker timestamps the install so launch.sh can detect manifest changes
  # (new pip deps in pyproject.toml) and trigger a reinstall on next launch.
  # Editable .py edits don't need this -- pipx symlinks the source, so they
  # take effect immediately.
  mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/bar-devtools"
  touch "${XDG_STATE_HOME:-$HOME/.local/state}/bar-devtools/bar-launch-installed"

  ok "bar-launch installed (entry point: $(command -v bar-launch || echo "~/.local/bin/bar-launch"))"

  if ! command -v bar-launch &>/dev/null; then
    warn "bar-launch isn't on PATH yet. Open a new shell, or run: pipx ensurepath"
  fi
}

cmd_setup_bar_launch() {
  local repo_path
  repo_path="$(bar_launch_repo_path)"
  if [ ! -d "$repo_path/bar_launch" ]; then
    info "bar_debug_launcher not checked out at $repo_path -- skipping bar-launch install."
    info "Add it via: just repos::clone bar (or set local_path in repos.local.conf)."
    return 0
  fi
  ensure_bar_launch_installed "$repo_path"
  ensure_bar_appimage_path_set
}

# Find a Beyond-All-Reason*.AppImage in $1, case-insensitive. Echoes path or
# nothing. Mirrors bar_launch.core's _APPIMAGE_RE.
_find_appimage_in_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  local f
  while IFS= read -r f; do
    echo "$f"
    return 0
  done < <(find "$dir" -maxdepth 1 -type f \( \
              -iname 'beyond-all-reason*.appimage' -o \
              -iname 'beyond_all_reason*.appimage' -o \
              -iname 'beyondallreason*.appimage' \) 2>/dev/null | sort -r)
}

# Resolve $BAR_APPIMAGE_PATH for the AppImage launcher boot path. Preserves
# existing values; auto-discovers ~/Applications first; falls back to a prompt.
# Non-interactive shells skip the prompt and just warn -- bar-launch's GUI
# still works for engine-direct boots, only --boot launcher needs this.
ensure_bar_appimage_path_set() {
  local env_file="$DEVTOOLS_DIR/.env"
  touch "$env_file"

  if grep -q "^BAR_APPIMAGE_PATH=" "$env_file" 2>/dev/null; then
    info "BAR_APPIMAGE_PATH already set in .env"
    return 0
  fi

  # Auto-discover the canonical AppImageLauncher location.
  local found
  found="$(_find_appimage_in_dir "$HOME/Applications")"
  if [ -n "$found" ]; then
    echo "BAR_APPIMAGE_PATH=$found" >> "$env_file"
    ok "Discovered AppImage at $found (added to .env)"
    return 0
  fi

  # Couldn't auto-discover. Prompt the user with the most-common locations.
  if ! [ -t 0 ]; then
    warn "Beyond-All-Reason AppImage not found in ~/Applications and no TTY for prompting."
    info "If you want '--boot launcher' to work, add to BAR-Devtools/.env:"
    info "  BAR_APPIMAGE_PATH=/path/to/Beyond-All-Reason.AppImage  (or a directory containing one)"
    info "Engine-direct boots (--boot engine) work without this."
    return 0
  fi

  echo ""
  warn "Beyond-All-Reason AppImage not found in ~/Applications."
  info "bar-launch needs this only when booting via the AppImage launcher"
  info "(--boot launcher / chobby default). Engine-direct boots don't."
  echo ""
  echo "  Common locations:"
  echo "    ~/Applications/Beyond-All-Reason.AppImage   (AppImageLauncher canonical)"
  echo "    ~/apps/<anywhere>/                          (directory containing the AppImage)"
  echo "    /opt/BAR/Beyond-All-Reason.AppImage"
  echo ""
  local response
  read -rp "Path to AppImage (or directory containing it; blank to skip): " response
  if [ -z "$response" ]; then
    warn "Skipped. '--boot launcher' will fail until BAR_APPIMAGE_PATH is set in .env."
    return 0
  fi

  # Expand ~ and validate.
  local expanded="${response/#\~/$HOME}"
  if [ -f "$expanded" ]; then
    echo "BAR_APPIMAGE_PATH=$expanded" >> "$env_file"
    ok "Added BAR_APPIMAGE_PATH=$expanded to .env"
  elif [ -d "$expanded" ]; then
    local resolved
    resolved="$(_find_appimage_in_dir "$expanded")"
    if [ -n "$resolved" ]; then
      # Persist the directory: if you upgrade the AppImage in-place, you
      # don't have to re-edit .env; bar_launch.core scans the dir.
      echo "BAR_APPIMAGE_PATH=$expanded" >> "$env_file"
      ok "Added BAR_APPIMAGE_PATH=$expanded to .env (resolves to $resolved)"
    else
      warn "$expanded is a directory but contains no Beyond-All-Reason*.AppImage."
      warn "Saving anyway -- the launcher will scan it again at run time."
      echo "BAR_APPIMAGE_PATH=$expanded" >> "$env_file"
    fi
  else
    err "$expanded does not exist."
    info "Edit BAR-Devtools/.env directly when you have the path:"
    info "  BAR_APPIMAGE_PATH=/path/to/Beyond-All-Reason.AppImage"
    return 1
  fi
}

# BAR_DATA_DIR: the engine's data dir -- where spring reads cache/, games/,
# engine/, and writes infolog.txt. On WSL2 this is a Windows-side path the
# sync daemon mirrors our WSL Devtools sources into (sync.sh + sync.py); on
# Linux, a real dir we symlink into. Persisted in .env on WSL2.

bar_data_dir_get() {
  local env_file="$DEVTOOLS_DIR/.env"
  if [ -f "$env_file" ]; then
    local val
    val="$(grep -E '^BAR_DATA_DIR=' "$env_file" 2>/dev/null | tail -n1 | cut -d= -f2-)"
    if [ -n "$val" ]; then
      val="${val%\"}"; val="${val#\"}"
      echo "$val"
      return 0
    fi
  fi
  echo "${BAR_DATA_DIR:-}"
}

_to_windows_path() {
  local p="$1"
  if command -v wslpath &>/dev/null; then
    wslpath -w "$p" 2>/dev/null || echo "$p"
  else
    echo "$p"
  fi
}

_to_wsl_path() {
  local p="$1"
  if command -v wslpath &>/dev/null; then
    wslpath -u "$p" 2>/dev/null || echo "$p"
  else
    echo "$p"
  fi
}

# Default: the BAR launcher's own data dir. We deliberately co-locate with
# it instead of using a separate scratch + junction -- spring's archive
# scanner doesn't traverse reparse points into game subdirs.
_default_bar_data_dir() {
  is_wsl || return 0
  command -v cmd.exe &>/dev/null || return 0
  command -v wslpath &>/dev/null || return 0
  local localappdata
  localappdata="$(cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r\n')"
  [ -z "$localappdata" ] && return 0
  case "$localappdata" in
    *%LOCALAPPDATA%*) return 0 ;;
  esac
  local wsl_path
  wsl_path="$(wslpath -u "$localappdata" 2>/dev/null)" || return 0
  local launcher_data="$wsl_path/Programs/Beyond-All-Reason/data"
  if [ -d "$launcher_data" ]; then
    echo "$launcher_data"
  else
    echo "$wsl_path/BAR-DevSync"
  fi
}

# Idempotently set `<key> = <value>` in a springsettings.cfg. If the key is
# already present (any whitespace / casing), replace its value; otherwise
# append. The engine treats unknown keys as warnings and rewrites the cfg
# on graceful shutdown -- so callers should re-apply on every launch rather
# than relying on prior writes surviving.
springsettings_set() {
  local cfg="${1:-}" key="${2:-}" value="${3:-}"
  if [ -z "$cfg" ] || [ -z "$key" ]; then
    return 1
  fi
  # Auto-create cfg if missing (engine creates a default on first run; if we
  # write before first run it'll merge ours with its defaults).
  if [ ! -f "$cfg" ]; then
    : > "$cfg" 2>/dev/null || { warn "Couldn't create $cfg"; return 1; }
  fi
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$cfg" 2>/dev/null; then
    local tmp="$cfg.tmp.$$"
    # Use # as sed delimiter so values with / don't bite us. Anchor on ^...$.
    sed -E "s#^[[:space:]]*${key}[[:space:]]*=.*\$#${key} = ${value}#" \
      "$cfg" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$cfg" \
      || { rm -f "$tmp"; warn "Couldn't update $key in $cfg"; return 1; }
  else
    printf '%s = %s\n' "$key" "$value" >> "$cfg" \
      || { warn "Couldn't append $key to $cfg"; return 1; }
  fi
}

# Drop an empty devmode.txt at the engine's data dir to enable Recoil's
# developer mode (unsigned LuaUI/gadgets, /cheat, hot-reload, loosened VFS
# write rules). Presence is what matters; content is ignored. Idempotent --
# never overwrites an existing file, and stays silent unless it creates one,
# so launch-time invocations don't spam the log.
ensure_devmode_marker() {
  local data_dir="${1:-}"
  [ -n "$data_dir" ] || return 0
  [ -d "$data_dir" ] || return 0
  local marker="$data_dir/devmode.txt"
  [ -e "$marker" ] && return 0
  # `2>/dev/null` on a single redirect only catches the command's stderr,
  # not the redirect-setup failure ("Permission denied" lands on bash's
  # stderr first). Wrap the redirect in `{}` so the suppressor sees both.
  if { : > "$marker"; } 2>/dev/null; then
    info "Created $marker (Recoil dev mode marker)"
  else
    warn "Couldn't create $marker (continuing without dev mode)"
  fi
}

# Persist the WSL path form -- the rest of the bash plumbing reads it
# directly. The Windows-side shim bakes in the converted Windows path.
ensure_bar_data_dir() {
  is_wsl || return 0

  local env_file="$DEVTOOLS_DIR/.env"
  touch "$env_file"

  local current
  current="$(bar_data_dir_get)"
  if [ -n "$current" ]; then
    info "BAR_DATA_DIR already set: $current"
  else
    echo ""
    info "WSL2 detected. Linux↔Windows symlinks aren't fast enough for runtime"
    info "game-Lua reads, so BAR-Devtools mirrors your Devtools checkouts to a"
    info "Windows-side data directory the engine reads from. The recommended"
    info "target is the BAR launcher's own data dir -- spring then sees our"
    info "synced bar/chobby/engine alongside its own cache/demos/settings"
    info "without any junctions in the path."
    echo ""
    echo "  Recommended:  %LOCALAPPDATA%\\Programs\\Beyond-All-Reason\\data\\"
    echo "                (the data dir Beyond-All-Reason.exe already writes to)"
    echo "  Avoid:        %USERPROFILE%\\Documents\\... (OneDrive redirection)"
    echo "                %TEMP%\\...                  (cleared on reboot)"
    echo "                \\\\wsl\$\\<distro>\\...        (defeats the whole point)"
    echo ""
    local default_path
    default_path="$(_default_bar_data_dir)"

    local response
    if [ -t 0 ]; then
      if [ -n "$default_path" ]; then
        read -rp "BAR data dir [$(_to_windows_path "$default_path")]: " response
      else
        read -rp "BAR data dir (WSL path or Windows path): " response
      fi
    else
      response=""
    fi

    if [ -z "$response" ]; then
      if [ -z "$default_path" ]; then
        err "No BAR_DATA_DIR provided and couldn't compute a default (cmd.exe / wslpath unavailable)."
        info "Edit BAR-Devtools/.env directly:  BAR_DATA_DIR=/mnt/c/Users/<you>/AppData/Local/BAR-DevSync"
        return 1
      fi
      current="$default_path"
    else
      case "$response" in
        /mnt/*|/home/*|/root/*) current="${response/#\~/$HOME}" ;;
        *)
          local converted
          converted="$(_to_wsl_path "$response")"
          if [ -z "$converted" ] || [ "$converted" = "$response" ]; then
            warn "Couldn't convert '$response' via wslpath -- saving as-is."
            current="$response"
          else
            current="$converted"
          fi
          ;;
      esac
    fi

    echo "BAR_DATA_DIR=$current" >> "$env_file"
    ok "Added BAR_DATA_DIR=$current to .env"
  fi

  local sub
  for sub in engine/local-build games/Beyond-All-Reason.sdd games/BYAR-Chobby.sdd bin; do
    mkdir -p "$current/$sub" 2>/dev/null || {
      err "Couldn't mkdir $current/$sub -- check that the path is reachable from WSL."
      return 1
    }
  done

  ensure_devmode_marker "$current"

  ok "BAR data dir ready: $current"

  export BAR_DATA_DIR="$current"
}

# Persist BAR_LAUNCH_PYTHON=<py.exe path> to .env. Called after
# ensure_windows_python finds a real interpreter so the shim and venv
# bootstrap have a stable handle to it. WSL-only.
ensure_bar_launch_python_persisted() {
  is_wsl || return 0
  local env_file="$DEVTOOLS_DIR/.env"
  touch "$env_file"

  if grep -q "^BAR_LAUNCH_PYTHON=" "$env_file" 2>/dev/null; then
    return 0
  fi

  local py_path
  py_path="$(command -v py.exe 2>/dev/null || true)"
  if ! _is_real_windows_python "$py_path"; then
    py_path="$(command -v python.exe 2>/dev/null || true)"
  fi
  if ! _is_real_windows_python "$py_path"; then
    return 0
  fi

  local win_py
  win_py="$(_to_windows_path "$py_path")"
  # Single-quote: backslashes in C:\... would otherwise be interpreted as
  # escape sequences by just's dotenv parser.
  echo "BAR_LAUNCH_PYTHON='$win_py'" >> "$env_file"
  ok "Added BAR_LAUNCH_PYTHON=$win_py to .env"
}

# A Windows venv (not a WSL one): Recoil runs as a native Windows process
# and the launcher spawns it via subprocess. Keeping the launcher itself
# Windows-side avoids a WSL→Windows hop on every engine spawn.
ensure_bar_launch_venv_windows() {
  is_wsl || return 0

  local data_dir_wsl="${BAR_DATA_DIR:-$(bar_data_dir_get)}"
  if [ -z "$data_dir_wsl" ]; then
    warn "BAR_DATA_DIR not set -- skipping Windows venv bootstrap."
    return 0
  fi

  local py_path
  py_path="$(command -v py.exe 2>/dev/null || true)"
  if ! _is_real_windows_python "$py_path"; then
    py_path="$(command -v python.exe 2>/dev/null || true)"
  fi
  if ! _is_real_windows_python "$py_path"; then
    warn "No real Windows Python found -- skipping venv bootstrap."
    info "Run 'just setup::init' again after installing Python on Windows."
    return 0
  fi

  local venv_wsl="$data_dir_wsl/.venv"
  local venv_python_wsl="$venv_wsl/Scripts/python.exe"

  if [ ! -x "$venv_python_wsl" ] && [ ! -f "$venv_python_wsl" ]; then
    step "Creating Windows venv at $venv_wsl"
    "$py_path" -3 -m venv "$(_to_windows_path "$venv_wsl")" \
      || { err "Failed to create venv at $venv_wsl"; return 1; }
  fi

  if [ ! -f "$venv_python_wsl" ]; then
    err "venv created but $venv_python_wsl is missing -- aborting."
    return 1
  fi

  local repo_path
  repo_path="$(bar_launch_repo_path)"
  if [ ! -f "$repo_path/pyproject.toml" ]; then
    err "bar_debug_launcher checkout missing at $repo_path -- skipping venv install."
    return 1
  fi

  step "Installing bar_debug_launcher into Windows venv"
  # Editable install via UNC path: pip writes a .pth into the venv, import
  # crosses Plan9 once on launcher startup -- fine for a once-per-session tool.
  local repo_unc
  repo_unc="$(_to_windows_path "$repo_path")"
  "$venv_python_wsl" -m pip install --upgrade pip --quiet \
    || warn "pip self-upgrade failed; continuing"
  "$venv_python_wsl" -m pip install --quiet --editable "$repo_unc" \
    || { err "pip install bar_debug_launcher failed"; return 1; }

  ok "Windows venv ready: $venv_wsl"
  export BAR_LAUNCH_VENV="$venv_wsl"
}

# Generate <BAR_DATA_DIR>/bin/bar-launch.cmd with absolute Windows paths
# baked in. Regenerate via `just bar::regen-shim` if .env values change.
regenerate_bar_launch_cmd_shim() {
  is_wsl || return 0

  local data_dir_wsl="${BAR_DATA_DIR:-$(bar_data_dir_get)}"
  if [ -z "$data_dir_wsl" ]; then
    err "BAR_DATA_DIR not set -- run 'just setup::init' on WSL first."
    return 1
  fi

  local venv_python_wsl="$data_dir_wsl/.venv/Scripts/python.exe"
  if [ ! -f "$venv_python_wsl" ]; then
    err "Windows venv python not found at $venv_python_wsl"
    info "Run 'just setup::init' to create it."
    return 1
  fi

  local shim_wsl="$data_dir_wsl/bin/bar-launch.cmd"
  mkdir -p "$(dirname "$shim_wsl")"

  local venv_python_win data_dir_win
  venv_python_win="$(_to_windows_path "$venv_python_wsl")"
  data_dir_win="$(_to_windows_path "$data_dir_wsl")"

  cat > "$shim_wsl" <<EOF
@echo off
REM Generated by BAR-Devtools setup. Edit via: just bar::regen-shim
"$venv_python_win" -m bar_launch --data-dir "$data_dir_win" %*
EOF
  sed -i 's/$/\r/' "$shim_wsl"

  ok "Generated $shim_wsl"
}

# Inspect the current state, list ONLY what's actually missing, then
# pre-cache sudo and continue. No Y/n: running setup::init is itself the
# consent. Press Enter is the user's chance to read what's about to
# happen; Ctrl-C aborts. When nothing is missing the splash is skipped
# entirely.
_setup_consent_splash() {
  is_wsl || return 0

  local need_apt=() cur_limit need_sysctl=0 need_distrobox_setup=0 need_distrobox_install=0
  python3 -c 'import watchdog' &>/dev/null || need_apt+=("python3-watchdog")
  command -v inotifywait &>/dev/null     || need_apt+=("inotify-tools")
  command -v rsync &>/dev/null           || need_apt+=("rsync")

  cur_limit="$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)"
  [ "$cur_limit" -lt 131072 ] && need_sysctl=1

  if ! command -v distrobox &>/dev/null; then
    need_distrobox_install=1
  elif ! distrobox list 2>/dev/null | grep -q "| $DEVTOOLS_DISTROBOX "; then
    need_distrobox_setup=1
  fi

  if [ "${#need_apt[@]}" -eq 0 ] && [ "$need_sysctl" = "0" ] \
     && [ "$need_distrobox_install" = "0" ] && [ "$need_distrobox_setup" = "0" ]; then
    info "System deps already in place; no install steps needed."
    return 0
  fi

  echo ""
  echo -e "${BOLD}=== System changes setup::init will make ===${NC}"
  echo ""

  if [ "${#need_apt[@]}" -gt 0 ]; then
    echo "  apt install (sudo):"
    local pkg
    for pkg in "${need_apt[@]}"; do
      echo "    $pkg"
    done
    echo ""
  fi

  if [ "$need_sysctl" = "1" ]; then
    echo "  sysctl drop-in (sudo, /etc/sysctl.d/99-bar-devtools.conf):"
    echo "    fs.inotify.max_user_watches=524288  (currently $cur_limit)"
    echo ""
  fi

  if [ "$need_distrobox_install" = "1" ]; then
    echo "  distrobox install (sudo apt):"
    echo "    distrobox          dev toolchain habitat"
    echo ""
  fi

  if [ "$need_distrobox_setup" = "1" ]; then
    echo "  distrobox container (~3-5min, network):"
    echo "    bar-dev    per docker/dev.Containerfile; toolchain habitat."
    echo "               Toolchain (emmylua_ls, clangd, stylua, lux, watchman)"
    echo "               exposed on host PATH via distrobox-export."
    echo ""
  fi

  echo "  Press Enter to proceed, Ctrl-C to abort."
  read -r _
  sudo -v 2>/dev/null || warn "sudo -v could not pre-cache credentials; subsequent steps may re-prompt."
}

# Verify the WSL-side sync daemon's deps are in place:
#   1. python3-watchdog (apt) -- the Observer's inotify backend.
#   2. fs.inotify.max_user_watches large enough for the BAR tree (~100k+
#      files including .git/, .lux/, vendored Lua). Distro default is 8192.
# Watchman (also a sync.py dep) lives inside the bar-dev container and is
# wired to host PATH by ensure_watchman_wsl, called from cmd_setup_distrobox
# after the container exists.
# Each of these requires sudo, so we don't install silently -- we report
# what's missing and surface the exact commands. Idempotent and safe to
# re-run; quiet when everything's already in place.
ensure_sync_daemon_deps_wsl() {
  is_wsl || return 0

  step "Checking WSL sync daemon deps"

  local missing=0

  if python3 -c 'import watchdog' &>/dev/null; then
    info "python3-watchdog: present"
  else
    step "  installing python3-watchdog (apt)"
    sudo apt-get install -y python3-watchdog >/dev/null 2>&1 \
      && ok "python3-watchdog installed" \
      || { err "python3-watchdog install failed"; missing=1; }
  fi

  if command -v inotifywait &>/dev/null; then
    info "inotify-tools: present"
  else
    step "  installing inotify-tools (apt)"
    sudo apt-get install -y inotify-tools >/dev/null 2>&1 \
      && ok "inotify-tools installed" \
      || warn "inotify-tools install failed"
  fi

  if command -v rsync &>/dev/null; then
    info "rsync: present"
  else
    step "  installing rsync (apt)"
    sudo apt-get install -y rsync >/dev/null 2>&1 \
      && ok "rsync installed" \
      || { err "rsync install failed"; missing=1; }
  fi

  # 524288 is the canonical bump everyone (watchdog, dropbox, jetbrains)
  # converges on; the kernel default of 8192 is below BAR's directory count.
  local cur_limit min_limit=131072
  cur_limit="$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)"
  if [ "$cur_limit" -ge "$min_limit" ]; then
    info "fs.inotify.max_user_watches=$cur_limit (≥ $min_limit)"
  else
    step "  bumping fs.inotify.max_user_watches → 524288 (sysctl drop-in)"
    if echo 'fs.inotify.max_user_watches=524288' \
         | sudo tee /etc/sysctl.d/99-bar-devtools.conf >/dev/null \
       && sudo sysctl -p /etc/sysctl.d/99-bar-devtools.conf >/dev/null 2>&1; then
      ok "fs.inotify.max_user_watches set to 524288"
    else
      warn "Could not write /etc/sysctl.d/99-bar-devtools.conf"
      missing=1
    fi
  fi

  if [ "$missing" = "1" ]; then
    warn "Some sync deps are still missing; sync daemon may not start cleanly."
    return 1
  fi
  ok "WSL sync daemon deps OK"
  return 0
}

# Wire watchman through to the host PATH via distrobox-export. Watchman
# is installed in the bar-dev container by dev.Containerfile; the
# wrapper at ~/.local/bin/watchman runs `distrobox enter -- watchman`
# so sync.py calls `watchman -j` like any host binary.
ensure_watchman_wsl() {
  # Don't short-circuit on `command -v watchman`: if setup::init runs from
  # inside bar-dev (where /usr/bin/watchman is on PATH from the dnf install),
  # that check returns 0 and we silently skip creating the host wrapper at
  # ~/.local/bin/watchman -- so later host invocations of sync.py find no
  # watchman at all. distrobox-export is idempotent; just always run it.
  step "exporting watchman from $DEVTOOLS_DISTROBOX → ~/.local/bin"
  mkdir -p "$HOME/.local/bin"
  distrobox enter "$DEVTOOLS_DISTROBOX" -- \
    distrobox-export --bin /usr/local/bin/watchman --export-path "$HOME/.local/bin" >/dev/null
  if [ ! -x "$HOME/.local/bin/watchman" ]; then
    err "distrobox-export ran but $HOME/.local/bin/watchman is missing or not executable"
    return 1
  fi
  ok "watchman wrapper exported"
}

DEV_IMAGE="bar-dev"

cmd_setup_distrobox() {
  echo -e "${BOLD}=== Distrobox Dev Environment ===${NC}"
  echo ""

  if ! command -v distrobox &>/dev/null; then
    err "distrobox is not installed. Run 'just setup::deps' first."
    exit 1
  fi

  ensure_wsl_setup

  # Persist the chosen container name to .env so the user can see/edit it.
  # The default itself lives in common.sh; this just makes it discoverable.
  local env_file="$DEVTOOLS_DIR/.env"
  touch "$env_file"
  if ! grep -q "^DEVTOOLS_DISTROBOX=" "$env_file" 2>/dev/null; then
    echo "DEVTOOLS_DISTROBOX=$DEVTOOLS_DISTROBOX" >> "$env_file"
    ok "Added DEVTOOLS_DISTROBOX=$DEVTOOLS_DISTROBOX to .env (edit to rename your box)"
  fi

  local runtime="podman"
  command -v podman &>/dev/null || runtime="docker"

  step "Building dev container image ($DEV_IMAGE)..."
  $runtime build -t "$DEV_IMAGE" -f "$DEVTOOLS_DIR/docker/dev.Containerfile" "$DEVTOOLS_DIR"
  ok "Image built: $DEV_IMAGE"
  echo ""

  distrobox stop --yes "$DEVTOOLS_DISTROBOX" >/dev/null 2>&1 || true
  distrobox rm -f --yes "$DEVTOOLS_DISTROBOX" >/dev/null 2>&1 \
    || $runtime rm -f "$DEVTOOLS_DISTROBOX" >/dev/null 2>&1 \
    || true

  step "Creating distrobox '$DEVTOOLS_DISTROBOX'..."
  local image_ref="$DEV_IMAGE"
  [ "$runtime" = "podman" ] && image_ref="localhost/$DEV_IMAGE"
  distrobox create --name "$DEVTOOLS_DISTROBOX" --image "$image_ref" --yes
  ok "Distrobox created: $DEVTOOLS_DISTROBOX"
  echo ""

  step "Running first-entry setup (lux lua tree)..."
  # Inner script must `set -e` so a failure in `lx install-lua` or the
  # symlink isn't swallowed by bash -c continuing past it. We leak the
  # exit through `distrobox enter` -> outer caller, which gets reported.
  if ! distrobox enter "$DEVTOOLS_DISTROBOX" -- bash -c '
    set -e
    lx install-lua
    LUA_BIN=$(command -v lua-5.1 2>/dev/null || command -v lua5.1 2>/dev/null)
    if [ -z "$LUA_BIN" ]; then
      echo "lux setup: no lua-5.1 binary found in container PATH" >&2
      exit 1
    fi
    LUX_LUA="$HOME/.local/share/lux/tree/5.1/.lua/bin/lua"
    mkdir -p "$(dirname "$LUX_LUA")"
    ln -sf "$LUA_BIN" "$LUX_LUA"
  '; then
    err "Lux lua tree setup failed inside bar-dev. Try 'just setup::distrobox' to rebuild."
    return 1
  fi
  ok "Lux lua tree configured"
  echo ""

  if is_wsl; then
    ensure_watchman_wsl || warn "watchman host wrapper not installed; sync daemon will fall back to full rsync."
    echo ""
  fi

  ok "Distrobox dev environment ready."
  echo ""
  echo "  Recipes that need lux/node/cargo will now run inside '$DEVTOOLS_DISTROBOX' automatically."
  echo "  To enter the box manually:  distrobox enter $DEVTOOLS_DISTROBOX"
  echo "  To rebuild after changes:   just setup::distrobox"
}

# Feature -> repo dirs it pulls in. Reads from the loaded repos.conf so the
# feature column is the single source of truth — no hand-maintained mapping
# in this file. Caller must have run load_repos_conf already.
feature_repos() {
  local feature="$1"
  local i out=""
  for i in "${!REPO_DIRS[@]}"; do
    if repo_has_feature "${REPO_FEATURES[$i]}" "$feature"; then
      out="${out}${REPO_DIRS[$i]} "
    fi
  done
  echo "${out% }"
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

# Note: features lives in scripts/setup/20-features.sh now. The module
# registers prompt_features / apply_features at source-load time, and
# cmd_init drives it through `ensure_module_by_name features`.

# Persist ALLOW_SPRINGSETTINGS_MOD=<0|1> to .env.
write_springsettings_optin_env() {
  local choice="$1"   # 1 to opt in, 0 to opt out
  local env_file="$DEVTOOLS_DIR/.env"
  touch "$env_file"
  if grep -q "^ALLOW_SPRINGSETTINGS_MOD=" "$env_file"; then
    sed -i "s|^ALLOW_SPRINGSETTINGS_MOD=.*|ALLOW_SPRINGSETTINGS_MOD=${choice}|" "$env_file"
    info "Updated ALLOW_SPRINGSETTINGS_MOD in .env: ${choice}"
  else
    echo "ALLOW_SPRINGSETTINGS_MOD=${choice}" >> "$env_file"
    ok "Added ALLOW_SPRINGSETTINGS_MOD=${choice} to .env"
  fi
}

# Ask the user once whether bar::launch is allowed to modify the engine's
# springsettings.cfg in service of its own --debug-* flags. Default no:
# the cfg is the user's territory and most contributors will never use
# the debug flags. Idempotent -- if the key is already set in .env, this
# is a no-op so re-running setup::init doesn't re-prompt.
prompt_springsettings_opt_in() {
  local env_file="$DEVTOOLS_DIR/.env"
  if [ -f "$env_file" ] && grep -q "^ALLOW_SPRINGSETTINGS_MOD=" "$env_file"; then
    info "ALLOW_SPRINGSETTINGS_MOD already set in .env -- not re-prompting"
    return 0
  fi

  echo ""
  echo -e "${BOLD}springsettings.cfg modification opt-in${NC}"
  echo "  Some bar::launch flags (currently --debug-gl) need to write keys to"
  echo "  the engine's springsettings.cfg. Without your permission this"
  echo "  launcher will refuse to touch the file -- the flags will warn and"
  echo "  no-op. The keys we manage are listed in scripts/launch.sh under"
  echo "  _MANAGED_SPRINGSETTINGS; nothing else in the cfg is read or written."
  echo ""
  read -r -p "Allow bar::launch to modify springsettings.cfg for its managed flags? [y/N] " ans
  case "${ans:-}" in
    y|Y|yes|YES) write_springsettings_optin_env 1 ;;
    *)           write_springsettings_optin_env 0 ;;
  esac
}

# Detect whether GitHub already accepts an SSH key from the running agent.
# Returns 0 if `ssh -T git@github.com` finds a configured key, 1 otherwise.
# BatchMode=yes prevents the password/yes prompts that would otherwise hang.
_github_ssh_works() {
  command -v ssh >/dev/null 2>&1 || return 1
  local out
  out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
              -o ConnectTimeout=5 -T git@github.com 2>&1)"
  printf '%s' "$out" | grep -q "successfully authenticated"
}

# Step-0 prompt: pick how the user wants SSH to GitHub configured. Skipped
# entirely when an agent already authenticates (no point in nagging users
# who arrived with a working setup) or when BAR_SSH_SETUP is already in
# .env (re-runs respect the prior choice; edit .env to re-decide). The
# actual setup runs later via run_ssh_setup_choice so the user can answer
# here and walk away during the long steps.
prompt_ssh_setup_choice() {
  local env_file="$DEVTOOLS_DIR/.env"
  touch "$env_file"
  if grep -q "^BAR_SSH_SETUP=" "$env_file"; then
    info "BAR_SSH_SETUP already set in .env -- not re-prompting"
    return 0
  fi
  if _github_ssh_works; then
    info "ssh -T git@github.com already authenticates -- skipping ssh setup prompt"
    echo "BAR_SSH_SETUP=existing" >> "$env_file"
    return 0
  fi

  echo ""
  echo -e "${BOLD}SSH to GitHub${NC}"
  echo "  No working SSH agent reaches github.com from this shell. Cloning"
  echo "  / pushing over HTTPS works but prompts for a token on every push,"
  echo "  and several BAR-Devtools recipes assume push-by-default. Pick how"
  echo "  you'd like to set up an SSH key now (we'll run the actual setup"
  echo "  after the long steps, you don't have to babysit this prompt):"
  echo ""
  echo "    1) op      1Password Desktop + agent bridge"
  echo "    2) manual  Generate ~/.ssh/id_ed25519 + walk through GitHub"
  echo "    3) skip    Don't configure now (clone over HTTPS; re-run later)"
  echo ""
  local ans choice=""
  while [ -z "$choice" ]; do
    read -r -p "Choice [1-3]: " ans
    case "${ans:-}" in
      1|op)      choice="op" ;;
      2|manual)  choice="manual" ;;
      3|skip|"") choice="skip" ;;
      *)         echo "  Invalid choice: ${ans}" ;;
    esac
  done
  echo "BAR_SSH_SETUP=$choice" >> "$env_file"
  ok "Recorded BAR_SSH_SETUP=$choice in .env"
}

# Run the SSH setup the user picked at step 0. Idempotent: re-running
# setup::init after a successful manual/op flow is a no-op (the setup
# scripts themselves detect "already configured").
run_ssh_setup_choice() {
  local env_file="$DEVTOOLS_DIR/.env"
  local choice
  choice="$(grep -E "^BAR_SSH_SETUP=" "$env_file" 2>/dev/null | tail -1 | cut -d= -f2-)"
  case "${choice:-skip}" in
    op)              bash "$DEVTOOLS_DIR/scripts/ssh/setup-op-ssh.sh"     || warn "ssh::op-setup failed; you can re-run it with 'just ssh::op-setup'." ;;
    manual)          bash "$DEVTOOLS_DIR/scripts/ssh/setup-manual-ssh.sh" || warn "ssh::manual-setup failed; you can re-run it with 'just ssh::manual-setup'." ;;
    existing|skip|*) : ;;
  esac
  # The ssh setup scripts append SSH_AUTH_SOCK to the user's rc, but the
  # currently running setup::init shell doesn't pick that up -- so a later
  # `git clone git@github.com:...` in this same process fails with
  # "Permission denied (publickey)". Export the socket here based on the
  # paths the wsl/linux scripts wire up.
  for _sock in "$HOME/.1password/agent.sock" "$HOME/.ssh/agent.sock"; do
    if [ -S "$_sock" ]; then
      export SSH_AUTH_SOCK="$_sock"
      break
    fi
  done
  unset _sock
}

# Editor integration: collects state for the front-load prompt and the
# unattended runner. Sets globals (intentionally global, mirrors how the
# other prompt_* helpers communicate state):
#   EDITOR_HAVE_CODE          1 if `code` CLI is on PATH
#   EDITOR_INSTALLED_EXTS     newline-separated list (from `code --list-extensions`)
#   EDITOR_MISSING_EXTS       space-separated subset of recommended extensions absent
#   EDITOR_HAS_SUMNEKO        1 if sumneko.lua is currently installed
_EDITOR_RECOMMENDED=(
  "tangzx.emmylua|EmmyLua (Lua language server)"
  "JohnnyMorganz.stylua|StyLua (Lua formatter)"
  "llvm-vs-code-extensions.vscode-clangd|clangd (C/C++ for engine work)"
)
editor_collect_state() {
  EDITOR_HAVE_CODE=0
  EDITOR_INSTALLED_EXTS=""
  EDITOR_MISSING_EXTS=""
  EDITOR_HAS_SUMNEKO=0
  command -v code >/dev/null 2>&1 || return 0
  EDITOR_HAVE_CODE=1
  EDITOR_INSTALLED_EXTS="$(code --list-extensions 2>/dev/null || true)"
  grep -qixF sumneko.lua <<<"$EDITOR_INSTALLED_EXTS" && EDITOR_HAS_SUMNEKO=1
  local entry ext miss=""
  for entry in "${_EDITOR_RECOMMENDED[@]}"; do
    ext="${entry%%|*}"
    grep -qixF "$ext" <<<"$EDITOR_INSTALLED_EXTS" || miss="${miss} ${ext}"
  done
  EDITOR_MISSING_EXTS="${miss# }"
}

# Render the recommended-extensions list. Caller already ran
# editor_collect_state and printed any heading it wants. Pulled out so the
# Step 0/N prompt and the standalone editor recipe stay byte-identical here.
_editor_render_state() {
  local entry ext label
  for entry in "${_EDITOR_RECOMMENDED[@]}"; do
    ext="${entry%%|*}"; label="${entry#*|}"
    if [ "${EDITOR_HAVE_CODE:-0}" = "1" ] && grep -qixF "$ext" <<<"$EDITOR_INSTALLED_EXTS"; then
      printf "  ${CYAN}✓${NC} %-40s %s ${DIM}(installed)${NC}\n" "$ext" "$label"
    elif [ "${EDITOR_HAVE_CODE:-0}" = "1" ]; then
      printf "  ${RED}✗${NC} %-40s %s ${DIM}(missing)${NC}\n"   "$ext" "$label"
    else
      printf "  ${DIM}?${NC} %-40s %s\n"                        "$ext" "$label"
    fi
  done
  # if/then/fi (not `[ ... ] && printf`) so the function returns 0 when
  # sumneko isn't installed -- otherwise set -e in the caller exits here.
  if [ "${EDITOR_HAS_SUMNEKO:-0}" = "1" ]; then
    printf "  ${YELLOW}!${NC} %-40s ${DIM}(installed; conflicts with tangzx.emmylua)${NC}\n" "sumneko.lua"
  fi
}

# Full "what this is and what it'll do" preamble, shared between the Step
# 0/N prompt (cmd_init) and the standalone editor recipe. Both touch this
# text — keeping it in one place means the prompt and recipe always agree.
_editor_show_preamble() {
  echo ""
  echo -e "${BOLD}Editor integration${NC}"
  echo "  Wires up your editor (VS Code, Cursor, VSCodium -- anything that finds"
  echo "  language servers on PATH) for BAR development:"
  echo "    - exports emmylua_ls, emmylua_check, clangd, stylua, lx to ~/.local/bin"
  echo "    - generates RecoilEngine/compile_commands.json for clangd"
  echo "    - writes Beyond-All-Reason/.vscode/settings.json (gitignored, per-checkout)"
  echo ""
  if [ "${EDITOR_HAVE_CODE:-0}" = "1" ]; then
    echo "  Detected: 'code' on PATH. Recommended VS Code extensions:"
    _editor_render_state
  else
    info "  'code' is not on PATH. Wiring still works for Cursor / non-vscode editors,"
    info "  but extensions can't be auto-installed -- handle them in your editor's UI."
  fi
  echo ""
}

# Top-level editor opt-in. Front-loaded into cmd_init's Step 0/N batch.
# Persists BAR_EDITOR_SETUP=yes|no; future runs skip re-prompting (matches
# how prompt_ssh_setup_choice / springsettings opt-in behave).
#
# One prompt, not three: the preamble's ✓/✗ list already previews exactly
# what `yes` will do (install the ✗ items, remove a flagged sumneko.lua),
# so a separate "install missing exts?" / "uninstall sumneko?" pair would
# just be the user re-stating what they already saw on screen.
prompt_editor_setup_choice() {
  local env_file="$DEVTOOLS_DIR/.env"
  touch "$env_file"
  if grep -q "^BAR_EDITOR_SETUP=" "$env_file"; then
    info "BAR_EDITOR_SETUP already set in .env -- not re-prompting"
    return 0
  fi

  editor_collect_state
  _editor_show_preamble

  local ans
  read -r -p "Wire up editor integration after the build? [Y/n] " ans
  case "${ans:-y}" in
    y|Y|yes|YES) echo "BAR_EDITOR_SETUP=yes" >> "$env_file" ;;
    *)           echo "BAR_EDITOR_SETUP=no"  >> "$env_file" ;;
  esac
}

# Read the persisted editor decisions from .env and run cmd_setup_editor if
# opted in. cmd_init's last unattended step before SSH setup.
run_editor_setup_choice() {
  local env_file="$DEVTOOLS_DIR/.env"
  local choice
  choice="$(grep -E "^BAR_EDITOR_SETUP=" "$env_file" 2>/dev/null | tail -1 | cut -d= -f2-)"
  case "${choice:-no}" in
    yes) cmd_setup_editor ;;
    *)   info "Editor integration skipped (declined at configuration step)." ;;
  esac
}

# Unattended editor wiring. Always installs the recommended extensions and
# removes a conflicting sumneko.lua if present -- the Step 0/N preamble
# previewed exactly this, so an explicit yes covers both. Both paths short-
# circuit when there's nothing to do (no missing exts / no sumneko).
cmd_setup_editor() {
  if [ -z "${DEVTOOLS_DISTROBOX:-}" ]; then
    err "DEVTOOLS_DISTROBOX not set. Run: just setup::distrobox"
    return 1
  fi

  local local_bin="$HOME/.local/bin" bin export_failures=()
  mkdir -p "$local_bin"
  for bin in /usr/local/bin/emmylua_ls /usr/local/bin/emmylua_check /usr/bin/clangd /usr/local/bin/stylua /usr/bin/lx; do
    info "Exporting $(basename "$bin")..."
    if ! distrobox enter "$DEVTOOLS_DISTROBOX" -- distrobox-export --bin "$bin" --export-path "$local_bin"; then
      export_failures+=("$bin")
    fi
  done
  if [ "${#export_failures[@]}" -gt 0 ]; then
    err "distrobox-export failed for: ${export_failures[*]}"
    err "  Most common cause: bar-dev container missing or down."
    err "  Recover with: just setup::distrobox && just setup::editor"
    return 1
  fi
  case ":$PATH:" in
    *":$local_bin:"*) ;;
    *)  warn "$local_bin is not on \$PATH; exported wrappers won't be found by your editor."
        warn "  Add to your shell rc:  export PATH=\"\$HOME/.local/bin:\$PATH\""
        ;;
  esac
  echo ""

  if [ -f "$DEVTOOLS_DIR/RecoilEngine/CMakeLists.txt" ]; then
    step "Generating compile_commands.json for clangd..."
    # Without pipefail the `| tail -3` swallows cmake's non-zero exit
    # (tail always succeeds), and we'd happily print "ready" against a
    # missing or stale build/compile_commands.json. set -e + pipefail
    # inside makes cmake's failure propagate.
    if ! distrobox enter "$DEVTOOLS_DISTROBOX" -- bash -c "
      set -eo pipefail
      cd '$DEVTOOLS_DIR/RecoilEngine' \
        && mkdir -p build \
        && cd build \
        && cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON .. 2>&1 | tail -3
    "; then
      err "cmake configure failed; compile_commands.json not generated."
      err "  Re-run 'just setup::editor' once the engine builds cleanly."
      return 1
    fi
    if [ ! -f "$DEVTOOLS_DIR/RecoilEngine/build/compile_commands.json" ]; then
      err "cmake reported success but build/compile_commands.json is missing."
      return 1
    fi
    ln -sf build/compile_commands.json "$DEVTOOLS_DIR/RecoilEngine/compile_commands.json"
    ok "compile_commands.json ready"
  else
    info "RecoilEngine not cloned -- skipping compile_commands.json"
  fi
  echo ""

  editor_collect_state
  if [ "$EDITOR_HAVE_CODE" = "1" ] && [ -n "$EDITOR_MISSING_EXTS" ]; then
    local ext
    for ext in $EDITOR_MISSING_EXTS; do
      code --install-extension "$ext" --force >/dev/null
      info "Installed $ext"
    done
    echo ""
  fi

  if [ "$EDITOR_HAS_SUMNEKO" = "1" ]; then
    code --uninstall-extension sumneko.lua >/dev/null
    ok "sumneko.lua uninstalled (conflicts with tangzx.emmylua)"
    echo ""
  fi

  info "Binaries exported to ~/.local/bin:"
  for bin in emmylua_ls emmylua_check clangd stylua lx; do
    if [ -x "$HOME/.local/bin/$bin" ]; then
      printf "  ${CYAN}✓ %s${NC}\n" "$bin"
    else
      printf "  ${RED}✗ %s${NC}  ${DIM}(missing -- rerun setup::editor)${NC}\n" "$bin"
    fi
  done
  echo ""

  # Per-checkout .vscode/settings.json (gitignored in both repos). The
  # engine template bakes in $HOME so clangd.path doesn't depend on
  # VS Code Server's PATH inheriting ~/.local/bin (it doesn't, reliably).
  _write_vscode_settings() {
    local repo="$1" template="$2"
    local dest="$DEVTOOLS_DIR/$repo/.vscode/settings.json"
    [ -d "$DEVTOOLS_DIR/$repo" ] || return 0
    local rendered
    rendered="$(sed "s|__HOME__|$HOME|g" "$template")"
    if [ ! -f "$dest" ]; then
      mkdir -p "$(dirname "$dest")"
      printf '%s\n' "$rendered" > "$dest"
      ok "Wrote $dest"
    elif ! diff -q <(printf '%s\n' "$rendered") "$dest" >/dev/null 2>&1; then
      warn "$dest differs from recommended defaults:"
      diff -u "$dest" <(printf '%s\n' "$rendered") | sed 's/^/  /' || true
      info "Merge by hand (or delete the file and re-run 'just setup::editor')."
    else
      info "$dest matches recommended defaults"
    fi
  }
  _write_vscode_settings "Beyond-All-Reason" "$DEVTOOLS_DIR/templates/bar-vscode-settings.json"
  _write_vscode_settings "RecoilEngine"      "$DEVTOOLS_DIR/templates/recoil-vscode-settings.json"
  unset -f _write_vscode_settings
  echo ""
  ok "Editor integration ready."
  echo ""
  info "If your editor was already open, reload the window (or run"
  info "'EmmyLua: Restart Server' and 'clangd: Restart language server')"
  info "so both extensions pick up the new binaries."
}

# Clone only the repos that map to the selected features.
clone_for_features() {
  local features="$1"
  if [ -z "$features" ]; then
    return 0
  fi
  load_repos_conf
  local wanted
  wanted="$(features_to_repos "$features")"

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
    local upstream_url="${REPO_UPSTREAM_URLS[$i]}"
    if [ -n "$local_path" ]; then
      clone_or_update_repo "$dir" "${REPO_URLS[$i]}" "${REPO_BRANCHES[$i]}" "$upstream_url" "$local_path"
      linked=$((linked + 1))
    elif [ -d "$DEVTOOLS_DIR/$dir/.git" ]; then
      clone_or_update_repo "$dir" "${REPO_URLS[$i]}" "${REPO_BRANCHES[$i]}" "$upstream_url"
      updated=$((updated + 1))
    else
      clone_or_update_repo "$dir" "${REPO_URLS[$i]}" "${REPO_BRANCHES[$i]}" "$upstream_url"
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

  # If they got this far they obviously have *some* `just`, but apt-shipped
  # 1.21 silently mis-parses our module syntax. Surface the version mismatch
  # before the long-running steps start.
  _check_just_min_version "1.31.0"

  ensure_wsl_setup
  _setup_consent_splash

  # ===== Front-load all interactive decisions =====
  # Everything below is one big batch of prompts so the user can answer
  # them up front and walk away while the long-running steps roll.
  if [ ! -f "$REPOS_CONF" ]; then
    err "repos.conf not found at: $REPOS_CONF"
    exit 1
  fi

  step "0/8  Configuration"
  echo ""
  if is_wsl; then
    ensure_bar_data_dir || warn "Skipping BAR data dir setup (set BAR_DATA_DIR in .env to retry)."
  fi

  ensure_module_by_name features || true
  local features
  features="$(read_env_key BAR_FEATURES)"
  if [ -z "$features" ]; then
    info "Skipping clone/build steps. Re-run 'just setup::init' to pick components."
    return 0
  fi

  # Symlink decision is captured now; actual linking happens in step 6,
  # once the repos exist on disk. Persisted as BAR_LINK_ON_BUILD.
  ensure_module_by_name link_on_build
  local game_dir do_link
  game_dir="$(detect_game_dir 2>/dev/null)" || true
  do_link="$(read_env_key BAR_LINK_ON_BUILD)"

  ensure_module_by_name chobby_channel  || true
  ensure_module_by_name springsettings  || true
  # ssh's apply runs the chosen setup-*.sh script -- still at config time,
  # so the rest of cmd_init is unattended (manual flow's "paste pubkey to
  # GitHub" pause happens here, not later).
  ensure_module_by_name ssh             || true
  # editor's apply (extension install) runs at config time too. The legacy
  # cmd_init had it at step 8/8, but cmd_setup_editor doesn't depend on
  # any later step; keeping it here matches the front-load pattern.
  ensure_module_by_name editor          || true
  echo ""

  step "1/8  Checking & installing dependencies"
  echo ""
  if check_git &>/dev/null && check_docker &>/dev/null; then
    ok "Core dependencies (git, docker) already installed."
  else
    cmd_install_deps || { err "Dependency installation failed. Fix and retry."; exit 1; }
  fi
  ensure_windows_python
  # Install python3-watchdog / inotify-tools / rsync up front: the engine build
  # in step 5 triggers `sync.sh mirror-engine` on success, which imports
  # watchdog. Leaving this for step 7 means a transient engine-build failure
  # aborts init before the deps the splash promised get installed.
  ensure_sync_daemon_deps_wsl
  echo ""

  step "2/8  Dev environment (distrobox -- required)"
  echo ""
  cmd_setup_distrobox
  echo ""

  step "3/8  Cloning repositories"
  echo ""
  clone_for_features "$features"
  echo ""

  step "4/8  Building Docker images"
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

  step "5/8  Engine build"
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
      # Via `just engine::build` (not build.sh) so the post-success
      # `sync.sh mirror-engine` hook seeds $BAR_DATA_DIR/engine/local-build.
      ( cd "$DEVTOOLS_DIR" && just engine::build --arch "$engine_arch" "$engine_os" )
    else
      warn "Recoil selected but RecoilEngine/docker-build-v2 missing -- clone may have failed."
    fi
  else
    info "Recoil not selected -- skipping engine build."
  fi
  echo ""

  step "6/8  Symlinks to game directory"
  echo ""
  if [ -z "$game_dir" ]; then
    info "No game directory detected. Set BAR_DATA_DIR to enable linking."
  elif [ "$do_link" = "yes" ]; then
    local available=() name
    features_include "$features" recoil && [ -d "$DEVTOOLS_DIR/RecoilEngine" ] && available+=("engine")
    features_include "$features" chobby && [ -d "$DEVTOOLS_DIR/BYAR-Chobby" ]    && available+=("chobby")
    features_include "$features" bar    && [ -d "$DEVTOOLS_DIR/Beyond-All-Reason" ] && available+=("bar")
    BAR_DATA_DIR="$game_dir"
    for name in "${available[@]}"; do
      cmd_link "$name"
    done

    # WSL2: pre-warm the Watchman cold-copy seed during init's AFK time.
    # The first `bar::launch` then hits the incremental-delta path
    # (seconds) instead of timing out on a full rsync of the source trees
    # through /mnt/c. _wait_for_ready in sync.sh has a 300s bound and a
    # fresh BAR + chobby seed has been observed to exceed it. Fail-soft:
    # the first bar::launch falls back to a full seed if this trips.
    if is_wsl; then
      echo ""
      info "Pre-warming sync state (cold-copy of source pairs to $BAR_DATA_DIR)"
      bash "$DEVTOOLS_DIR/scripts/sync.sh" cold-copy \
        || warn "Pre-warm failed; first 'just bar::launch' will fall back to a full rsync seed."
    fi
  else
    info "Skipping symlinks (declined at configuration step)."
  fi
  echo ""

  step "7/8  bar-launch venv (just bar::launch)"
  echo ""
  if is_wsl; then
    # On WSL2 the launcher runs as a Windows-side Python process so it
    # talks to the Windows engine binary directly. The Linux pipx venv
    # would force WSL→Windows IPC for every engine spawn.
    ensure_bar_launch_venv_windows && regenerate_bar_launch_cmd_shim
  else
    cmd_setup_bar_launch
  fi
  echo ""

  step "8/8  Deferred module apply (editor, etc.)"
  echo ""
  apply_deferred_modules
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
    echo -e "    ${BOLD}just bar::launch${NC}              Launch the engine against your local checkout"
    echo -e "    ${BOLD}just services::up lobby${NC}       Launch bar-lobby and connect"
    echo -e "    ${BOLD}just bar::units${NC}               Run busted Lua unit tests"
    echo -e "    ${BOLD}just bar::units-shell${NC}         Drop into an interactive busted shell"
    echo -e "    ${BOLD}just bar::check${NC}               EmmyLua type-check across the repo"
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

  # cmd_setup is the docker-compose teiserver stack init. It needs the
  # teiserver feature repos (teiserver, spads_config_bar, …); auto-clone
  # them if any are missing.
  local missing_teiserver=0
  load_repos_conf
  for i in "${!REPO_DIRS[@]}"; do
    if repo_has_feature "${REPO_FEATURES[$i]}" "teiserver" \
       && [ ! -d "$DEVTOOLS_DIR/${REPO_DIRS[$i]}/.git" ]; then
      missing_teiserver=1
      break
    fi
  done

  if [ "$missing_teiserver" -eq 1 ]; then
    warn "Teiserver repositories are missing. Cloning them now..."
    echo ""
    cmd_clone teiserver
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
  if [ -n "${BAR_DATA_DIR:-}" ]; then
    echo "$BAR_DATA_DIR"
    return 0
  fi

  # On WSL2 the dev-mode data dir is the sync target: that's where the
  # engine reads cache/, demos/, the synced games/, and the local engine
  # build from. Prefer it over the upstream Windows installer's data dir,
  # which has no Devtools content in it.
  if is_wsl; then
    local data_dir
    data_dir="$(bar_data_dir_get)"
    if [ -n "$data_dir" ] && [ -d "$data_dir" ]; then
      echo "$data_dir"
      return 0
    fi
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
      warn "Game directory not found. Set BAR_DATA_DIR env var or install BAR to the default location."
      echo ""
      return 0
    fi
    info "Game directory: ${game_dir}"
    echo ""

    # game subdirs end in .sdd so spring's archive scanner registers them
    # (without the suffix, scan() walks the dir but never registers it as
    # a known archive, and --menu lookups fail content_error).
    local -A link_map=(
      [engine]="$game_dir/engine/local-build"
      [chobby]="$game_dir/games/BYAR-Chobby.sdd"
      [bar]="$game_dir/games/Beyond-All-Reason.sdd"
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
    err "Game directory not found. Set BAR_DATA_DIR env var or install BAR to the default location."
    exit 1
  fi

  ensure_devmode_marker "$game_dir"

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
      link_path="$game_dir/games/BYAR-Chobby.sdd"
      ;;
    bar)
      source_path="$DEVTOOLS_DIR/Beyond-All-Reason"
      link_path="$game_dir/games/Beyond-All-Reason.sdd"
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
      echo "  Clone the repo first: just repos::clone $target"
    fi
    exit 1
  fi

  # WSL2: link::create is a no-op for the symlink itself. The sync daemon
  # (scripts/sync.sh + scripts/sync.py) is the analogue of the symlink: it
  # mirrors source_path on WSL ext4 to link_path on Windows NTFS. We just
  # need the target subdir present so the engine doesn't choke on an empty
  # games/ dir; the cold-copy + watchman clock seed runs either at
  # setup::init's pre-warm step or on the next `bash scripts/sync.sh
  # cold-copy` / `just bar::launch`. Doing a raw rsync here would be a
  # slow duplicate -- it doesn't record the watchman clock sync.py needs.
  if is_wsl; then
    if [ ! -d "$source_path" ]; then
      err "Source not present at $source_path -- can't register sync target."
      return 1
    fi
    mkdir -p "$link_path"
    info "WSL2: $target tracks $source_path -> $link_path (via sync daemon)"
    info "  Mirror updates run via the sync daemon (seeded by setup::init or bar::launch)."
    ok "Tracked $target: $link_path (mirrors $source_path)"
    return 0
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

# ---------------------------------------------------------------------------
# Module registry: source the engine + load every scripts/setup/NN-*.sh
# module file. Each module registers itself via register_module so cmd_init
# can drive them uniformly through ensure_all_modules / ensure_module_by_name.
#
# This MUST run after every setup.sh helper is defined (modules call into
# checkbox_list, info/warn/ok, repo helpers, etc.).
# ---------------------------------------------------------------------------
# shellcheck source=scripts/setup/_lib.sh
source "$DEVTOOLS_DIR/scripts/setup/_lib.sh"
_load_setup_modules
