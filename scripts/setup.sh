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

# ---------------------------------------------------------------------------
# WSL2 sync target (Phase 3): BAR_DEVSYNC_DIR -- Windows-side data dir that
# the engine reads from, with three Devtools subpaths kept in sync from WSL.
# See bar-design-docs/bar_launch/plan.md (Phase 3).
# ---------------------------------------------------------------------------

# Read BAR_DEVSYNC_DIR from .env (preferred) or the current env. Echoes the
# WSL path form (/mnt/c/...) -- the canonical form we persist. Empty if unset.
bar_devsync_dir_get() {
  local env_file="$DEVTOOLS_DIR/.env"
  if [ -f "$env_file" ]; then
    local val
    val="$(grep -E '^BAR_DEVSYNC_DIR=' "$env_file" 2>/dev/null | tail -n1 | cut -d= -f2-)"
    if [ -n "$val" ]; then
      # Strip optional surrounding quotes.
      val="${val%\"}"; val="${val#\"}"
      echo "$val"
      return 0
    fi
  fi
  echo "${BAR_DEVSYNC_DIR:-}"
}

# Convert a WSL /mnt/c/... path to a Windows C:\... path. Falls back to the
# input if wslpath isn't available (non-WSL hosts shouldn't call this).
_to_windows_path() {
  local p="$1"
  if command -v wslpath &>/dev/null; then
    wslpath -w "$p" 2>/dev/null || echo "$p"
  else
    echo "$p"
  fi
}

# Convert a Windows C:\... path to a WSL /mnt/c/... path. Same fallback.
_to_wsl_path() {
  local p="$1"
  if command -v wslpath &>/dev/null; then
    wslpath -u "$p" 2>/dev/null || echo "$p"
  else
    echo "$p"
  fi
}

# Echo the WSL form of the BAR launcher's own data dir, or empty if we
# can't reach Windows. We default BAR_DEVSYNC_DIR to the launcher's data
# directory (where Beyond-All-Reason.exe puts cache/, demos/, infolog.txt,
# etc.) so the engine reads our synced bar/chobby/engine from a single
# canonical location -- no junctions, no second data dir. The launcher's
# install path follows BAR's installer's `%LOCALAPPDATA%\Programs\
# Beyond-All-Reason\` convention; if a contributor installed somewhere
# else they can override via the prompt.
_default_devsync_dir() {
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
  # The launcher's data dir (where its cache/, demos/, infolog.txt live).
  # Spring's archive scanner registers our games/ entries here cleanly --
  # earlier attempts that put sync in a separate dir + junctioned into
  # this one failed because spring's scanner doesn't traverse reparse
  # points into game subdirs.
  local launcher_data="$wsl_path/Programs/Beyond-All-Reason/data"
  if [ -d "$launcher_data" ]; then
    echo "$launcher_data"
  else
    # Fallback: a fresh dir under LOCALAPPDATA. The contributor will need
    # to either install BAR or junction <launcher>/data themselves.
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

# WSL2-only: prompt for BAR_DEVSYNC_DIR, persist to .env, create the three
# subpaths the sync daemon mirrors into plus bin/ for the cmd shim. Idempotent;
# safe to re-run after an upgrade.
#
# We persist the WSL path form so the rest of the bash plumbing reads it
# directly without wslpath conversion. The Windows-side shim is generated
# with the literal Windows path baked in (see regenerate_bar_launch_cmd_shim).
ensure_bar_devsync_dir() {
  is_wsl || return 0

  local env_file="$DEVTOOLS_DIR/.env"
  touch "$env_file"

  local current
  current="$(bar_devsync_dir_get)"
  if [ -n "$current" ]; then
    info "BAR_DEVSYNC_DIR already set: $current"
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
    default_path="$(_default_devsync_dir)"

    local response
    if [ -t 0 ]; then
      if [ -n "$default_path" ]; then
        read -rp "BAR sync dir [$(_to_windows_path "$default_path")]: " response
      else
        read -rp "BAR sync dir (WSL path or Windows path): " response
      fi
    else
      response=""
    fi

    if [ -z "$response" ]; then
      if [ -z "$default_path" ]; then
        err "No BAR_DEVSYNC_DIR provided and couldn't compute a default (cmd.exe / wslpath unavailable)."
        info "Edit BAR-Devtools/.env directly:  BAR_DEVSYNC_DIR=/mnt/c/Users/<you>/AppData/Local/BAR-DevSync"
        return 1
      fi
      current="$default_path"
    else
      # Accept either form. wslpath -u on a /mnt/... path is a no-op; on a
      # Windows path it converts. Tolerate both via wslpath probing.
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

    echo "BAR_DEVSYNC_DIR=$current" >> "$env_file"
    ok "Added BAR_DEVSYNC_DIR=$current to .env"
  fi

  # Create the directory tree. The sync daemon writes into the three rsync
  # targets; the engine creates everything else (cache/, demos/, infolog.txt,
  # settings) on first run. bin/ holds the cmd shim.
  local sub
  for sub in engine/local-build games/Beyond-All-Reason.sdd games/BYAR-Chobby.sdd bin; do
    mkdir -p "$current/$sub" 2>/dev/null || {
      err "Couldn't mkdir $current/$sub -- check that the path is reachable from WSL."
      return 1
    }
  done

  ensure_devmode_marker "$current"

  ok "BAR data dir ready: $current"

  export BAR_DEVSYNC_DIR="$current"
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

  # Resolve through wslpath -w so the persisted value is the Windows path
  # (the shim references it via cmd.exe; the venv bootstrap calls it from
  # WSL but `command -v` re-finds it either way).
  local win_py
  win_py="$(_to_windows_path "$py_path")"
  # Single-quote: backslashes in the Windows path (e.g. C:\Users\...) would
  # otherwise be interpreted as escape sequences by just's dotenv parser.
  echo "BAR_LAUNCH_PYTHON='$win_py'" >> "$env_file"
  ok "Added BAR_LAUNCH_PYTHON=$win_py to .env"
}

# Bootstrap a Windows venv at <BAR_DEVSYNC_DIR>/.venv and install
# bar_debug_launcher (editable) plus watchdog (sync daemon dep) into it.
# Idempotent: skips if the venv's bar-launch entry point already exists and
# the marker is newer than the launcher's pyproject.toml.
#
# Why a Windows venv specifically: the Recoil engine must run as a native
# Windows process, and the bar-launch CLI invokes it via subprocess. Running
# bar-launch from WSL → cmd.exe spring.exe works, but we'd then have two
# Pythons in the picture (WSL + Windows) for no benefit. Single Windows venv
# keeps the launch path uniform.
ensure_bar_launch_venv_windows() {
  is_wsl || return 0

  local devsync_wsl="${BAR_DEVSYNC_DIR:-$(bar_devsync_dir_get)}"
  if [ -z "$devsync_wsl" ]; then
    warn "BAR_DEVSYNC_DIR not set -- skipping Windows venv bootstrap."
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

  local venv_wsl="$devsync_wsl/.venv"
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

  step "Installing bar_debug_launcher + watchdog into Windows venv"
  # pip install on the Windows side. UNC path to the WSL repo works for an
  # editable install -- pip writes a .pth file, and import-time resolution
  # crosses Plan9 once on launcher startup. A minor cost for a tool that
  # runs once per dev session.
  local repo_unc
  repo_unc="$(_to_windows_path "$repo_path")"
  "$venv_python_wsl" -m pip install --upgrade pip --quiet \
    || warn "pip self-upgrade failed; continuing"
  "$venv_python_wsl" -m pip install --quiet --editable "$repo_unc" watchdog \
    || { err "pip install bar_debug_launcher + watchdog failed"; return 1; }

  ok "Windows venv ready: $venv_wsl"
  export BAR_LAUNCH_VENV="$venv_wsl"
}

# Generate <BAR_DEVSYNC_DIR>/bin/bar-launch.cmd with absolute Windows paths
# baked in. The shim is a dumb forwarder -- the Python in the venv does all
# the real work. Regenerated by `just bar::regen-shim` if .env values change.
#
# Requirements: BAR_DEVSYNC_DIR set, the venv's python.exe present.
regenerate_bar_launch_cmd_shim() {
  is_wsl || return 0

  local devsync_wsl="${BAR_DEVSYNC_DIR:-$(bar_devsync_dir_get)}"
  if [ -z "$devsync_wsl" ]; then
    err "BAR_DEVSYNC_DIR not set -- run 'just setup::init' on WSL first."
    return 1
  fi

  local venv_python_wsl="$devsync_wsl/.venv/Scripts/python.exe"
  if [ ! -f "$venv_python_wsl" ]; then
    err "Windows venv python not found at $venv_python_wsl"
    info "Run 'just setup::init' to create it."
    return 1
  fi

  local shim_wsl="$devsync_wsl/bin/bar-launch.cmd"
  mkdir -p "$(dirname "$shim_wsl")"

  local venv_python_win devsync_win
  venv_python_win="$(_to_windows_path "$venv_python_wsl")"
  devsync_win="$(_to_windows_path "$devsync_wsl")"

  # CRLF line endings: it's a .cmd file consumed by cmd.exe. Mostly cosmetic
  # but stays consistent with how Windows shells render it in an editor.
  cat > "$shim_wsl" <<EOF
@echo off
REM Generated by BAR-Devtools setup. Edit via: just bar::regen-shim
"$venv_python_win" -m bar_launch --data-dir "$devsync_win" %*
EOF
  # Convert LF -> CRLF in place. unix2dos is the conventional tool but isn't
  # always installed; sed handles it portably.
  sed -i 's/$/\r/' "$shim_wsl"

  ok "Generated $shim_wsl"
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
  if is_wsl; then
    ensure_bar_devsync_dir || warn "Skipping BAR sync dir setup (set BAR_DEVSYNC_DIR in .env to retry)."
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

  step "6/7  Symlinks to game directory"
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

  step "7/7  bar-launch venv (just bar::launch)"
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
  if [ -n "${BAR_GAME_DIR:-}" ]; then
    echo "$BAR_GAME_DIR"
    return 0
  fi

  # On WSL2 the dev-mode data dir is the sync target: that's where the
  # engine reads cache/, demos/, the synced games/, and the local engine
  # build from. Prefer it over the upstream Windows installer's data dir,
  # which has no Devtools content in it.
  if is_wsl; then
    local devsync
    devsync="$(bar_devsync_dir_get)"
    if [ -n "$devsync" ] && [ -d "$devsync" ]; then
      echo "$devsync"
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
      warn "Game directory not found. Set BAR_GAME_DIR env var or install BAR to the default location."
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
    err "Game directory not found. Set BAR_GAME_DIR env var or install BAR to the default location."
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
  # need the target subdir present (so the engine doesn't choke on an empty
  # games/ dir) and an initial cold-copy so dev edits land somewhere usable
  # before the watcher comes online on the next `just bar::launch`.
  if is_wsl; then
    if [ ! -d "$source_path" ]; then
      err "Source not present at $source_path -- can't seed sync target."
      return 1
    fi
    mkdir -p "$link_path"
    info "WSL2: $target tracks $source_path -> $link_path (via sync daemon)"
    if command -v rsync &>/dev/null; then
      info "Seeding $link_path with an initial cold copy"
      # Exclude list mirrors sync.py's _SKIP_DIRS plus .github/.gitignore --
      # the engine's archive scanner walks the whole .sdd, and multi-GB of
      # .git internals will either crash it (older Recoil) or refuse to
      # register the archive at all (alpha-tagged 2026.06.04+ surfaces this
      # as `Dependent archive "BYAR Chobby local" not found`). The watcher
      # already skips these, so this only matters for the cold-copy seed.
      rsync -a --delete --inplace \
        --exclude='.git' --exclude='.github' \
        --exclude='__pycache__' --exclude='node_modules' \
        --exclude='.gitignore' \
        "$source_path/" "$link_path/" \
        || warn "rsync seed failed; 'just bar::launch' will cold-copy on first run."
    else
      warn "rsync not installed; skipping seed ('just bar::launch' will cold-copy on first run)."
    fi
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
