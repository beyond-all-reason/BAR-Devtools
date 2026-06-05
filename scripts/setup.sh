#!/usr/bin/env bash
# Expects DEVTOOLS_DIR, COMPOSE, REPOS_CONF (exported by Justfile); source common.sh + repos.sh first.

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
  # No debian:container-compose entry -- Debian's apt compose is too old; see install_compose_upstream.
  case "${distro}:${generic}" in
    arch:container-runtime)    echo "podman" ;;
    arch:container-compose)    echo "docker-compose" ;;
    arch:git)                  echo "git" ;;
    arch:distrobox)            echo "distrobox" ;;
    debian:container-runtime)  echo "podman" ;;
    debian:git)                echo "git" ;;
    debian:distrobox)          echo "distrobox" ;;
    fedora:container-runtime)  echo "podman" ;;
    fedora:container-compose)  echo "docker-compose" ;;
    fedora:git)                echo "git" ;;
    fedora:distrobox)          echo "distrobox" ;;
    *)                         echo "$generic" ;;
  esac
}

check_git() {
  if ! command -v git &>/dev/null; then
    err "git is not installed."
    return 1
  fi
  ok "git $(git --version | awk '{print $3}') detected"
}

check_podman() {
  if ! command -v podman &>/dev/null; then
    err "podman is not installed."
    return 1
  fi
  if ! podman info &>/dev/null; then
    err "podman is installed but 'podman info' failed (storage init issue?)."
    info "  Try a fresh init:  podman system reset  (destroys local images)"
    return 1
  fi
  # podman compose delegates to the buggy python podman-compose unless the Go binary is present.
  if ! command -v docker-compose &>/dev/null; then
    err "docker-compose not installed (podman compose dispatcher needs it as provider)."
    info "  Run: just setup::deps"
    return 1
  fi
  local sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
  if [ ! -S "$sock" ]; then
    err "podman socket not active at $sock (docker-compose can't reach the daemon)."
    info "  Run: just setup::deps"
    return 1
  fi
  ok "podman $(podman --version | awk '{print $3}') + docker-compose $(docker-compose version --short 2>/dev/null) + socket detected"
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
  check_podman    || failed=1
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

# WSL2: enable systemd, mark / as a shared mount (needed for podman distrobox). No-op elsewhere.
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
      warn "  BAR-Devtools' container path needs systemd; flip it manually if that's a mistake."
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

  if [ "$(ps -p 1 -o comm= 2>/dev/null)" != "systemd" ] || [ "$needs_shutdown" -eq 1 ]; then
    echo ""
    warn "WSL must restart to pick up systemd."
    warn "  From Windows PowerShell:  wsl --shutdown"
    warn "  Then reopen WSL and re-run: just setup::init"
    exit 0
  fi

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
  wsl_virtiofs_hint
  echo ""
}

# True if $1 is a real Windows Python, not the Microsoft Store stub under WindowsApps.
_is_real_windows_python() {
  local p="$1"
  [ -n "$p" ] || return 1
  case "$p" in
    *WindowsApps*python.exe|*WindowsApps*py.exe) return 1 ;;
  esac
  return 0
}

# Install Python on the Windows host via winget. WSL-only; skips if a real Windows Python exists.
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

# Install distrobox from upstream; need >= 1.8.2.3 for the chpasswd fix against shadow-utils 4.13+.
install_distrobox_upstream() {
  local current
  current="$(/usr/local/bin/distrobox --version 2>/dev/null | awk '{print $NF}')"
  if [ -n "$current" ] && _ver_ge "$current" "1.8.2.3"; then
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

# Docker Compose v5+ from upstream releases. Compose v2.x defaults to bake/BuildKit, which podman
# can't drive; v5 degrades gracefully. Skips if v5+ is already on PATH.
install_compose_upstream() {
  local min_version="5.0.0"
  local pin_version="5.1.3"
  local current=""
  if command -v docker-compose &>/dev/null; then
    current="$(docker-compose version --short 2>/dev/null | sed 's/^v//')"
  fi
  if [ -n "$current" ] && _ver_ge "$current" "$min_version"; then
    ok "docker-compose ${current} already installed (>= ${min_version})"
    return 0
  fi

  local arch
  case "$(uname -m)" in
    x86_64)  arch="x86_64" ;;
    aarch64) arch="aarch64" ;;
    *) err "install_compose_upstream: unsupported arch $(uname -m)"; return 1 ;;
  esac

  local plugin_dir="/usr/local/lib/docker/cli-plugins"
  local target="${plugin_dir}/docker-compose"
  local symlink="/usr/local/bin/docker-compose"
  local url="https://github.com/docker/compose/releases/download/v${pin_version}/docker-compose-linux-${arch}"

  info "Installing docker-compose v${pin_version} from upstream releases (apt's is ${current:-missing})..."
  sudo mkdir -p "$plugin_dir"
  sudo curl -fsSL "$url" -o "$target"
  sudo chmod +x "$target"
  sudo ln -sf "$target" "$symlink"
  hash -r
  ok "docker-compose installed: $(docker-compose version --short 2>/dev/null)"
}

cmd_install_deps() {
  # Host-only: package post-install scriptlets need a real systemd, absent in rootless containers.
  require_host

  echo -e "${BOLD}=== Install System Dependencies ===${NC}"
  echo ""

  local distro
  distro="$(detect_distro)"
  local install_cmd
  install_cmd="$(pkg_install_cmd)"

  if [ "$distro" = "unknown" ] || [ -z "$install_cmd" ]; then
    err "Unsupported distro. Install these manually: git, podman, docker-compose >= 5.0, distrobox"
    info "See docker/dev.Containerfile for the full list of dev tool dependencies."
    exit 1
  fi

  info "Detected distro: ${BOLD}${distro}${NC}"
  echo ""

  local missing=()

  if ! command -v git &>/dev/null; then
    missing+=("git")
  fi
  if ! command -v podman &>/dev/null; then
    missing+=("container-runtime")
  fi
  # Debian gets compose from install_compose_upstream below, never from apt.
  if [ "$distro" != "debian" ] && ! command -v docker-compose &>/dev/null; then
    missing+=("container-compose")
  fi
  if ! command -v distrobox &>/dev/null; then
    missing+=("distrobox")
  fi

  # Debian gets distrobox from upstream; drop it from the apt list.
  local apt_missing=()
  for tool in "${missing[@]}"; do
    if [ "$distro" = "debian" ] && [ "$tool" = "distrobox" ]; then continue; fi
    apt_missing+=("$tool")
  done

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

  if [ "$distro" = "debian" ]; then
    install_distrobox_upstream
    echo ""
  fi
  install_compose_upstream
  echo ""

  ensure_podman_socket
  echo ""

  ok "Dependencies installed successfully."
}

# Enable podman.socket + loginctl linger so the user systemd socket survives logout (WSL2 needs this).
ensure_podman_socket() {
  if ! systemctl --user is-enabled podman.socket &>/dev/null; then
    info "Enabling user systemd podman.socket..."
    systemctl --user enable podman.socket
  fi
  if ! systemctl --user is-active podman.socket &>/dev/null; then
    info "Starting user systemd podman.socket..."
    systemctl --user start podman.socket
  fi

  if ! loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes'; then
    info "Enabling loginctl linger for ${USER} (so podman.socket survives logout)..."
    sudo loginctl enable-linger "$USER"
  fi

  local sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
  if [ -S "$sock" ]; then
    ok "podman socket active at $sock"
  else
    err "podman.socket says active but $sock isn't there. Try: systemctl --user restart podman.socket"
    return 1
  fi
}

# Resolve the bar_debug_launcher checkout, honoring a repos.local.conf override.
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

# True on rpm-ostree systems, where the package layer is read-only at runtime.
_is_ostree() {
  command -v rpm-ostree &>/dev/null && [ -e /run/ostree-booted ]
}

# Install pipx if missing. On rpm-ostree, bootstrap it via `pip install --user`.
_ensure_pipx() {
  if command -v pipx &>/dev/null; then return 0; fi

  if _is_ostree; then
    info "rpm-ostree system detected -- bootstrapping pipx via 'pip install --user'"
    if ! command -v python3 &>/dev/null; then
      err "python3 not found on PATH"
      return 1
    fi
    # --break-system-packages: PEP 668 EXTERNALLY-MANAGED; only touches ~/.local site-packages.
    python3 -m pip install --user --break-system-packages --quiet pipx \
      || { err "pip install --user pipx failed"; return 1; }
    python3 -m pipx ensurepath >/dev/null 2>&1 || true
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

# Find a Python >= 3.10 that can `import tkinter`. Probes /usr/bin paths so a pyenv shim can't shadow it.
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

# Editable-install the launcher with pipx, exposing the `bar-launch` entry point on PATH.
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
  # Uninstall first: `pipx install --force` ignores --python when reusing an existing venv.
  pipx uninstall bar-launch >/dev/null 2>&1 || true
  pipx uninstall bar_launch >/dev/null 2>&1 || true
  pipx install --editable --python "$target_py" "$repo_path"

  # Marker lets launch.sh detect pyproject.toml manifest changes and trigger a reinstall.
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

# Echo a Beyond-All-Reason*.AppImage found in $1 (case-insensitive), or nothing.
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

# Resolve BAR_APPIMAGE_PATH: keep existing, else auto-discover ~/Applications, else prompt.
ensure_bar_appimage_path_set() {
  local env_file="$DEVTOOLS_DIR/.env"
  touch "$env_file"

  if grep -q "^BAR_APPIMAGE_PATH=" "$env_file" 2>/dev/null; then
    info "BAR_APPIMAGE_PATH already set in .env"
    return 0
  fi

  local found
  found="$(_find_appimage_in_dir "$HOME/Applications")"
  if [ -n "$found" ]; then
    echo "BAR_APPIMAGE_PATH=$found" >> "$env_file"
    ok "Discovered AppImage at $found (added to .env)"
    return 0
  fi

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

  local expanded="${response/#\~/$HOME}"
  if [ -f "$expanded" ]; then
    echo "BAR_APPIMAGE_PATH=$expanded" >> "$env_file"
    ok "Added BAR_APPIMAGE_PATH=$expanded to .env"
  elif [ -d "$expanded" ]; then
    local resolved
    resolved="$(_find_appimage_in_dir "$expanded")"
    if [ -n "$resolved" ]; then
      # Persist the directory, not the file, so in-place AppImage upgrades don't need a .env edit.
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

# BAR_DATA_DIR: the engine's data dir. WSL2 mirrors sources into it; Linux symlinks into it.

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

# Default to the BAR launcher's own data dir: spring's archive scanner won't traverse junctions.
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

# Idempotently set `<key> = <value>` in a springsettings.cfg. The engine rewrites the cfg on
# shutdown, so callers should re-apply on every launch.
springsettings_set() {
  local cfg="${1:-}" key="${2:-}" value="${3:-}"
  if [ -z "$cfg" ] || [ -z "$key" ]; then
    return 1
  fi
  if [ ! -f "$cfg" ]; then
    : > "$cfg" 2>/dev/null || { warn "Couldn't create $cfg"; return 1; }
  fi
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$cfg" 2>/dev/null; then
    local tmp="$cfg.tmp.$$"
    # # as sed delimiter so values with / don't bite us.
    sed -E "s#^[[:space:]]*${key}[[:space:]]*=.*\$#${key} = ${value}#" \
      "$cfg" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$cfg" \
      || { rm -f "$tmp"; warn "Couldn't update $key in $cfg"; return 1; }
  else
    printf '%s = %s\n' "$key" "$value" >> "$cfg" \
      || { warn "Couldn't append $key to $cfg"; return 1; }
  fi
}

# Drop an empty devmode.txt at the engine's data dir to enable Recoil's developer mode.
ensure_devmode_marker() {
  local data_dir="${1:-}"
  [ -n "$data_dir" ] || return 0
  [ -d "$data_dir" ] || return 0
  local marker="$data_dir/devmode.txt"
  [ -e "$marker" ] && return 0
  # {} around the redirect so 2>/dev/null also catches a redirect-setup failure.
  if { : > "$marker"; } 2>/dev/null; then
    info "Created $marker (Recoil dev mode marker)"
  else
    warn "Couldn't create $marker (continuing without dev mode)"
  fi
}

# Persist BAR_DATA_DIR in WSL path form; the Windows shim converts it. WSL-only.
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

# Persist BAR_LAUNCH_PYTHON=<py.exe path> to .env. WSL-only.
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
  # Single-quote: just's dotenv parser would treat backslashes in C:\... as escapes.
  echo "BAR_LAUNCH_PYTHON='$win_py'" >> "$env_file"
  ok "Added BAR_LAUNCH_PYTHON=$win_py to .env"
}

# Build a Windows venv (not WSL): the launcher spawns the native Windows engine, avoiding a WSL hop.
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
  local repo_unc
  repo_unc="$(_to_windows_path "$repo_path")"
  "$venv_python_wsl" -m pip install --upgrade pip --quiet \
    || warn "pip self-upgrade failed; continuing"
  "$venv_python_wsl" -m pip install --quiet --editable "$repo_unc" \
    || { err "pip install bar_debug_launcher failed"; return 1; }

  ok "Windows venv ready: $venv_wsl"
  export BAR_LAUNCH_VENV="$venv_wsl"
}

# Generate <BAR_DATA_DIR>/bin/bar-launch.cmd with absolute Windows paths baked in.
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

# Show every decision + the work ahead, then gate on a single Y/n.
confirm_setup_plan() {
  local features="$1" game_dir="$2" do_link="$3"

  echo ""
  echo -e "${BOLD}=== setup::init will now make these changes ===${NC}"
  echo ""

  echo "  Your choices:"
  summarize_modules
  echo ""

  echo "  System (host):"
  echo "    install any missing packages -- git, podman, distrobox (needs sudo)"
  # grep -F not -q: under pipefail, -q's early exit SIGPIPEs `distrobox list` and flips the result.
  local dbx_built=0 dbx_listing
  if command -v distrobox >/dev/null 2>&1; then
    dbx_listing="$(distrobox list 2>/dev/null || true)"
    if printf '%s\n' "$dbx_listing" | grep -F "| $DEVTOOLS_DISTROBOX " >/dev/null 2>&1; then
      dbx_built=1
    fi
  fi
  if [ "$dbx_built" = 1 ]; then
    echo "    bar-dev distrobox: already built"
  else
    echo "    build the bar-dev distrobox container (~3-5 min, downloads a base image)"
  fi
  if is_wsl; then
    echo "    build the bar-sync distrobox container (WSL filesystem mirror)"
    echo "    raise fs.inotify.max_user_watches via /etc/sysctl.d (needs sudo)"
  fi
  echo ""

  # Bucket selected repos into present vs new (same test as clone_for_features).
  load_repos_conf
  local wanted i dir lp r_present=0 r_new=0 new_dirs=()
  wanted="$(features_to_repos "$features")"
  for i in "${!REPO_DIRS[@]}"; do
    dir="${REPO_DIRS[$i]}"
    [[ " $wanted " == *" $dir "* ]] || continue
    lp="${REPO_LOCAL_PATHS[$i]}"
    if { [ -n "$lp" ] && [ -d "$lp" ]; } \
       || { [ -z "$lp" ] && [ -d "$DEVTOOLS_DIR/$dir/.git" ]; }; then
      r_present=$((r_present + 1))
    else
      r_new=$((r_new + 1))
      new_dirs+=("$dir")
    fi
  done
  echo "  Repositories (${r_present} present, ${r_new} to clone):"
  [ "$r_present" -gt 0 ] && echo "    ${r_present} already here -- just fetching updates"
  if [ "$r_new" -gt 0 ]; then
    echo "    ${r_new} new -- cloned over the network:"
    echo "      ${new_dirs[*]}"
  fi
  echo ""

  if feature_selected teiserver || feature_selected recoil; then
    echo "  Build:"
    if feature_selected teiserver; then
      echo "    teiserver Docker image (compiles Elixir deps, generates TLS certs)"
    fi
    if feature_selected recoil; then
      echo "    Recoil engine from source (long -- tens of minutes)"
    fi
    echo ""
  fi

  if [ -n "$game_dir" ] && [ "$do_link" = "yes" ]; then
    echo "  Symlink into ${game_dir}:"
    if feature_selected recoil; then echo "    engine/local-build"; fi
    if feature_selected chobby; then echo "    games/BYAR-Chobby.sdd"; fi
    if feature_selected bar;    then echo "    games/Beyond-All-Reason.sdd"; fi
    echo ""
  fi

  echo "  Right after you confirm you'll be asked for your sudo password once"
  echo "  (package install / sysctl); the rest then runs unattended."
  echo ""
  local ans
  read -rp "  Proceed? [Y/n] " ans
  if [[ "$ans" =~ ^[Nn] ]]; then
    info "Cancelled -- nothing has been changed."
    exit 0
  fi
  sudo -v 2>/dev/null || warn "Could not pre-cache sudo; later steps may prompt for your password."
  echo ""
}

# Bump fs.inotify.max_user_watches on the host kernel; the BAR tree blows past the default.
ensure_sync_daemon_deps_wsl() {
  is_wsl || return 0

  step "Checking WSL sync kernel limits"

  local cur_limit min_limit=131072
  cur_limit="$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)"
  if [ "$cur_limit" -ge "$min_limit" ]; then
    info "fs.inotify.max_user_watches=$cur_limit (≥ $min_limit)"
    ok "WSL sync kernel limits OK"
    return 0
  fi

  step "  bumping fs.inotify.max_user_watches → 524288 (sysctl drop-in)"
  if echo 'fs.inotify.max_user_watches=524288' \
       | sudo tee /etc/sysctl.d/99-bar-devtools.conf >/dev/null \
     && sudo sysctl -p /etc/sysctl.d/99-bar-devtools.conf >/dev/null 2>&1; then
    ok "fs.inotify.max_user_watches set to 524288"
    return 0
  fi
  warn "Could not write /etc/sysctl.d/99-bar-devtools.conf -- watcher may miss events on deep subtrees"
  return 1
}

# Container paths of dev binaries exported to the host PATH via distrobox-export.
DEV_BINARIES=(
  /usr/local/bin/emmylua_ls
  /usr/local/bin/emmylua_check
  /usr/bin/clangd
  /usr/local/bin/stylua
  /usr/local/bin/lx
)

export_dev_binaries() {
  local local_bin="$HOME/.local/bin" bin export_failures=()
  mkdir -p "$local_bin"
  step "Exporting dev binaries from $DEVTOOLS_DISTROBOX → $local_bin"
  for bin in "${DEV_BINARIES[@]}"; do
    info "  $(basename "$bin")"
    if ! distrobox enter "$DEVTOOLS_DISTROBOX" -- distrobox-export --bin "$bin" --export-path "$local_bin" >/dev/null; then
      export_failures+=("$bin")
    fi
  done
  if [ "${#export_failures[@]}" -gt 0 ]; then
    err "distrobox-export failed for: ${export_failures[*]}"
    err "  The bar-dev image may be missing some dnf packages."
    err "  Recover with: just setup::distrobox"
    return 1
  fi
  case ":$PATH:" in
    *":$local_bin:"*) ;;
    *)  warn "$local_bin is not on \$PATH; exported wrappers won't be found by your editor or 'just' recipes."
        warn "  Add to your shell rc:  export PATH=\"\$HOME/.local/bin:\$PATH\""
        ;;
  esac
  ok "Dev binaries exported"
}

DEV_IMAGE="bar-dev"

cmd_setup_distrobox() {
  require_host

  # --rebuild forces a recreate even when the dev image is unchanged.
  local force_rebuild=0 arg
  for arg in "$@"; do
    if [ "$arg" = "--rebuild" ]; then force_rebuild=1; fi
  done

  echo -e "${BOLD}=== Distrobox Dev Environment ===${NC}"
  echo ""

  if ! command -v distrobox &>/dev/null; then
    err "distrobox is not installed. Run 'just setup::deps' first."
    exit 1
  fi

  ensure_wsl_setup

  local env_file="$DEVTOOLS_DIR/.env"
  touch "$env_file"
  if ! grep -q "^DEVTOOLS_DISTROBOX=" "$env_file" 2>/dev/null; then
    echo "DEVTOOLS_DISTROBOX=$DEVTOOLS_DISTROBOX" >> "$env_file"
    ok "Added DEVTOOLS_DISTROBOX=$DEVTOOLS_DISTROBOX to .env (edit to rename your box)"
  fi

  step "Building dev container image ($DEV_IMAGE)..."
  podman build -t "$DEV_IMAGE" -f "$DEVTOOLS_DIR/docker/dev.Containerfile" "$DEVTOOLS_DIR"
  ok "Image built: $DEV_IMAGE"
  echo ""

  # Recreate the container only when the image id changed; empty id => always recreate.
  local dev_image_id stamp_file image_changed=0
  dev_image_id="$(podman image inspect --format '{{.Id}}' "$DEV_IMAGE" 2>/dev/null || true)"
  stamp_file="$DEVTOOLS_DIR/.devtools/dev-image.id"
  if [ -z "$dev_image_id" ] || [ ! -f "$stamp_file" ] \
     || [ "$dev_image_id" != "$(cat "$stamp_file" 2>/dev/null)" ]; then
    image_changed=1
  fi

  local box_exists=0 dbx_list need_recreate=0
  dbx_list="$(distrobox list 2>/dev/null || true)"
  if printf '%s\n' "$dbx_list" | grep -F "| $DEVTOOLS_DISTROBOX " >/dev/null 2>&1; then
    box_exists=1
  fi
  if [ "$force_rebuild" = "1" ] || [ "$image_changed" = "1" ] || [ "$box_exists" = "0" ]; then
    need_recreate=1
  fi

  if [ "$need_recreate" = "1" ]; then
    distrobox stop --yes "$DEVTOOLS_DISTROBOX" >/dev/null 2>&1 || true
    distrobox rm -f --yes "$DEVTOOLS_DISTROBOX" >/dev/null 2>&1 \
      || podman rm -f "$DEVTOOLS_DISTROBOX" >/dev/null 2>&1 \
      || true
  fi

  mkdir -p "$(dirname "$stamp_file")"
  if [ -n "$dev_image_id" ]; then
    printf '%s\n' "$dev_image_id" > "$stamp_file"
  fi

  if [ "$need_recreate" = "1" ]; then
    step "Creating distrobox '$DEVTOOLS_DISTROBOX'..."
    # localhost/ prefix so distrobox uses the local image instead of pulling from a registry.
    distrobox create --name "$DEVTOOLS_DISTROBOX" --image "localhost/$DEV_IMAGE" --yes
    ok "Distrobox created: $DEVTOOLS_DISTROBOX"
  else
    ok "Distrobox '$DEVTOOLS_DISTROBOX' kept (dev image unchanged)."
  fi
  echo ""

  export_dev_binaries || warn "Some dev binaries failed to export; recipes / editor that depend on them will need 'just setup::distrobox' rerun."
  echo ""

  if is_wsl; then
    cmd_setup_sync_distrobox || warn "bar-sync container build failed; 'just bar::launch' will not be able to mirror edits to /mnt/c."
    echo ""
  fi

  ok "Distrobox dev environment ready."
  echo ""
  echo "  Recipes that need lux/node/cargo will now run inside '$DEVTOOLS_DISTROBOX' automatically."
  echo "  To enter the box manually:  distrobox enter $DEVTOOLS_DISTROBOX"
  echo "  To rebuild after changes:   just setup::distrobox"
}

# WSL-only: build + create the bar-sync container hosting the filesystem mirror daemon.
SYNC_IMAGE="bar-sync"
cmd_setup_sync_distrobox() {
  is_wsl || return 0

  # Called on the LHS of `||`, so set -e is off here -- every failure needs an explicit `|| return 1`.
  step "Building sync container image ($SYNC_IMAGE)..."
  if ! podman build -t "$SYNC_IMAGE" -f "$DEVTOOLS_DIR/docker/sync.Containerfile" "$DEVTOOLS_DIR"; then
    err "podman build failed for $SYNC_IMAGE -- see output above for the real cause."
    return 1
  fi
  ok "Image built: $SYNC_IMAGE"

  distrobox stop --yes "$DEVTOOLS_SYNC_DISTROBOX" >/dev/null 2>&1 || true
  distrobox rm -f --yes "$DEVTOOLS_SYNC_DISTROBOX" >/dev/null 2>&1 \
    || podman rm -f "$DEVTOOLS_SYNC_DISTROBOX" >/dev/null 2>&1 \
    || true

  step "Creating distrobox '$DEVTOOLS_SYNC_DISTROBOX'..."
  if ! distrobox create --name "$DEVTOOLS_SYNC_DISTROBOX" --image "localhost/$SYNC_IMAGE" --yes; then
    err "distrobox create failed for $DEVTOOLS_SYNC_DISTROBOX."
    return 1
  fi
  ok "Distrobox created: $DEVTOOLS_SYNC_DISTROBOX"

  # Smoke-test pywatchman + watchman before sync.sh relies on them.
  if ! distrobox enter "$DEVTOOLS_SYNC_DISTROBOX" -- python3 -c \
       'import pywatchman; pywatchman.client(timeout=5).query("version")' \
       >/dev/null 2>&1; then
    err "pywatchman + watchman smoke test failed inside $DEVTOOLS_SYNC_DISTROBOX"
    return 1
  fi
  ok "pywatchman + watchman ready in $DEVTOOLS_SYNC_DISTROBOX"
}

# Feature -> repo dirs it pulls in (from the loaded repos.conf). Caller must run load_repos_conf first.
feature_repos() {
  local feature="$1"
  local i out=""
  for i in "${!REPO_DIRS[@]}"; do
    if features_include "${REPO_FEATURES[$i]}" "$feature"; then
      out="${out}${REPO_DIRS[$i]} "
    fi
  done
  echo "${out% }"
}

# Comma-separated features -> deduplicated space-separated repo dirs.
features_to_repos() {
  local f r
  local -a flist=()
  declare -A seen=()
  IFS=',' read -ra flist <<< "$1"
  for f in "${flist[@]}"; do
    for r in $(feature_repos "$f"); do
      seen[$r]=1
    done
  done
  echo "${!seen[@]}"
}

# Interactive checkbox list; items are "key|label|default". Sets CHECKBOX_RESULT, returns 1 on quit.
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

# yes/no prompt; $2 = default on empty input. 0=yes 1=no.
ask_yes_no() {
  local q="$1" def="$2" ans hint
  [ "$def" = "y" ] && hint="[Y/n]" || hint="[y/N]"
  read -r -p "$q $hint " ans
  case "${ans:-$def}" in
    y|Y|yes|YES) return 0 ;;
    *)           return 1 ;;
  esac
}

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

# Ask once whether bar::launch may modify the engine's springsettings.cfg. Default no.
prompt_springsettings_opt_in() {
  echo ""
  echo -e "${BOLD}springsettings.cfg modification opt-in${NC}"
  echo "  Some bar::launch flags (currently --debug-gl) need to write keys to"
  echo "  the engine's springsettings.cfg. Without your permission this"
  echo "  launcher will refuse to touch the file -- the flags will warn and"
  echo "  no-op. The keys we manage are listed in scripts/launch.sh under"
  echo "  _MANAGED_SPRINGSETTINGS; nothing else in the cfg is read or written."
  echo ""
  local def=n
  [ "$(read_env_key ALLOW_SPRINGSETTINGS_MOD)" = "1" ] && def=y
  if ask_yes_no "Allow bar::launch to modify springsettings.cfg for its managed flags?" "$def"; then
    write_springsettings_optin_env 1
  else
    write_springsettings_optin_env 0
  fi
}

# 0 if `ssh -T git@github.com` already authenticates. BatchMode prevents a hang on prompts.
_github_ssh_works() {
  command -v ssh >/dev/null 2>&1 || return 1
  local out
  out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
              -o ConnectTimeout=5 -T git@github.com 2>&1)"
  printf '%s' "$out" | grep -q "successfully authenticated"
}

# Step-0 prompt: pick how SSH to GitHub gets configured. Skips when an agent already authenticates.
prompt_ssh_setup_choice() {
  if [ -z "${BAR_RESET_CONFIG:-}" ] && _github_ssh_works; then
    info "ssh -T git@github.com already authenticates -- skipping ssh setup prompt"
    write_env_key BAR_SSH_SETUP existing
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
  # Default to the saved choice; existing/skip/unset all land on 3.
  local cur defnum
  cur="$(read_env_key BAR_SSH_SETUP)"
  case "$cur" in
    op)     defnum=1 ;;
    manual) defnum=2 ;;
    *)      defnum=3 ;;
  esac
  local ans choice=""
  while [ -z "$choice" ]; do
    read -r -p "Choice [1-3] (default ${defnum}): " ans
    case "${ans:-$defnum}" in
      1|op)      choice="op" ;;
      2|manual)  choice="manual" ;;
      3|skip)    choice="skip" ;;
      *)         echo "  Invalid choice: ${ans}" ;;
    esac
  done
  write_env_key BAR_SSH_SETUP "$choice"
  ok "Recorded BAR_SSH_SETUP=$choice in .env"
}

# Run the SSH setup the user picked at step 0.
run_ssh_setup_choice() {
  local env_file="$DEVTOOLS_DIR/.env"
  local choice
  choice="$(grep -E "^BAR_SSH_SETUP=" "$env_file" 2>/dev/null | tail -1 | cut -d= -f2-)"
  case "${choice:-skip}" in
    op)              bash "$DEVTOOLS_DIR/scripts/ssh/setup-op-ssh.sh"     || warn "ssh::op-setup failed; you can re-run it with 'just ssh::op-setup'." ;;
    manual)          bash "$DEVTOOLS_DIR/scripts/ssh/setup-manual-ssh.sh" || warn "ssh::manual-setup failed; you can re-run it with 'just ssh::manual-setup'." ;;
    existing|skip|*) : ;;
  esac
  # Export SSH_AUTH_SOCK now so a `git clone` later in this same process can see it.
  for _sock in "$HOME/.1password/agent.sock" "$HOME/.ssh/agent.sock"; do
    if [ -S "$_sock" ]; then
      export SSH_AUTH_SOCK="$_sock"
      break
    fi
  done
  unset _sock
}

_EDITOR_RECOMMENDED=(
  "tangzx.emmylua|EmmyLua (Lua language server)"
  "JohnnyMorganz.stylua|StyLua (Lua formatter)"
  "llvm-vs-code-extensions.vscode-clangd|clangd (C/C++ for engine work)"
)
# Sets EDITOR_HAVE_CODE / EDITOR_INSTALLED_EXTS / EDITOR_MISSING_EXTS / EDITOR_HAS_SUMNEKO.
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

# Render the recommended-extensions list. Caller runs editor_collect_state first.
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
  # if/then/fi (not `&&`) so the function returns 0 under set -e when sumneko is absent.
  if [ "${EDITOR_HAS_SUMNEKO:-0}" = "1" ]; then
    printf "  ${YELLOW}!${NC} %-40s ${DIM}(installed; conflicts with tangzx.emmylua)${NC}\n" "sumneko.lua"
  fi
}

# Editor-integration preamble, shared by the Step 0/N prompt and the standalone editor recipe.
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

# Editor opt-in prompt. Persists BAR_EDITOR_SETUP=yes|no.
prompt_editor_setup_choice() {
  editor_collect_state
  _editor_show_preamble

  local def=y
  [ "$(read_env_key BAR_EDITOR_SETUP)" = "no" ] && def=n
  if ask_yes_no "Wire up editor integration after the build?" "$def"; then
    write_env_key BAR_EDITOR_SETUP yes
  else
    write_env_key BAR_EDITOR_SETUP no
  fi
}

# Run cmd_setup_editor if BAR_EDITOR_SETUP says yes.
run_editor_setup_choice() {
  local env_file="$DEVTOOLS_DIR/.env"
  local choice
  choice="$(grep -E "^BAR_EDITOR_SETUP=" "$env_file" 2>/dev/null | tail -1 | cut -d= -f2-)"
  case "${choice:-no}" in
    yes) cmd_setup_editor ;;
    *)   info "Editor integration skipped (declined at configuration step)." ;;
  esac
}

# Unattended editor wiring: installs recommended extensions, removes a conflicting sumneko.lua.
cmd_setup_editor() {
  if [ -z "${DEVTOOLS_DISTROBOX:-}" ]; then
    err "DEVTOOLS_DISTROBOX not set. Run: just setup::distrobox"
    return 1
  fi

  # Dev binaries are exported by setup::distrobox; bail loudly if they're missing.
  local local_bin="$HOME/.local/bin" bin missing_bins=()
  for bin in emmylua_ls emmylua_check clangd stylua lx; do
    [ -x "$local_bin/$bin" ] || missing_bins+=("$bin")
  done
  if [ "${#missing_bins[@]}" -gt 0 ]; then
    err "Dev binary wrappers missing in $local_bin: ${missing_bins[*]}"
    err "  These are exported by setup::distrobox. Run: just setup::distrobox"
    return 1
  fi

  if [ -f "$DEVTOOLS_DIR/RecoilEngine/CMakeLists.txt" ]; then
    step "Generating compile_commands.json for clangd..."
    # set -eo pipefail inside so `| tail -3` doesn't swallow a cmake failure.
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

  info "Binaries exported to ~/.local/bin (by setup::distrobox):"
  for bin in emmylua_ls emmylua_check clangd stylua lx; do
    if [ -x "$HOME/.local/bin/$bin" ]; then
      printf "  ${CYAN}✓ %s${NC}\n" "$bin"
    else
      printf "  ${RED}✗ %s${NC}  ${DIM}(missing -- rerun setup::distrobox)${NC}\n" "$bin"
    fi
  done
  echo ""

  # Per-checkout .vscode/settings.json; the engine template bakes in $HOME for clangd.path.
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

  local i cloned=0 updated=0 linked=0 pruned=0
  for i in "${!REPO_DIRS[@]}"; do
    local dir="${REPO_DIRS[$i]}"
    if [[ " $wanted " != *" $dir "* ]]; then
      # Deselected: drop a workspace symlink, or move a real clone to .backups/ (never delete).
      local target="$DEVTOOLS_DIR/$dir"
      if [ -L "$target" ]; then
        info "  ${dir}: deselected -- removing workspace symlink ($(readlink "$target") kept)"
        rm "$target"
        pruned=$((pruned + 1))
      elif [ -d "$target" ]; then
        local backup="$DEVTOOLS_DIR/.backups/${dir}-$(date +%Y%m%d-%H%M%S)"
        warn "  ${dir}: deselected -- moving workspace copy to ${backup}"
        mkdir -p "$DEVTOOLS_DIR/.backups"
        mv "$target" "$backup"
        pruned=$((pruned + 1))
      fi
      continue
    fi

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
  [ "$pruned" -gt 0 ] && summary+=", ${pruned} pruned"
  ok "Repos: ${summary}"
}

# status recap collected through cmd_init; rendered at the end
SETUP_RECAP=()
recap() { SETUP_RECAP+=("$1|$2|$3"); }   # label|status(ok|skip|warn)|detail

render_setup_recap() {
  local entry label status detail glyph color
  for entry in "${SETUP_RECAP[@]}"; do
    IFS='|' read -r label status detail <<<"$entry"
    case "$status" in
      ok)   glyph="✓"; color="$GREEN" ;;
      skip) glyph="∘"; color="$DIM" ;;
      warn) glyph="⚠"; color="$YELLOW" ;;
      *)    glyph="·"; color="$NC" ;;
    esac
    printf '  %b%s %-16s%b %b%s%b\n' "$color" "$glyph" "$label" "$NC" "$DIM" "$detail" "$NC"
  done
}

cmd_init() {
  require_host
  SETUP_RECAP=()

  echo -e "${BOLD}==========================================${NC}"
  echo -e "${BOLD}  BAR Dev Environment - First Time Setup${NC}"
  echo -e "${BOLD}==========================================${NC}"
  echo ""

  # apt-shipped just 1.21 silently mis-parses our module syntax.
  _check_just_min_version "1.31.0"

  ensure_wsl_setup

  # Front-load all interactive decisions so the user can answer and walk away.
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

  # Remaining modules are feature-gated via module_relevant.
  # Symlink decision is captured now; actual linking happens in step 6.
  local game_dir do_link
  if module_relevant link_on_build; then
    ensure_module_by_name link_on_build
  fi
  game_dir="$(detect_game_dir 2>/dev/null)" || true
  do_link="$(read_env_key BAR_LINK_ON_BUILD)"

  if module_relevant chobby_channel; then ensure_module_by_name chobby_channel || true; fi
  if module_relevant springsettings; then ensure_module_by_name springsettings || true; fi
  ensure_module_by_name ssh             || true
  # editor's apply is deferred to step 8 -- distrobox-export needs the container from step 2.
  if module_relevant editor; then ensure_module_by_name editor || true; fi
  echo ""

  confirm_setup_plan "$features" "$game_dir" "$do_link"

  step "1/8  Checking & installing dependencies"
  echo ""
  if check_git &>/dev/null && check_podman &>/dev/null; then
    ok "Core dependencies (git, podman) already installed."
    recap "Dependencies" ok "already installed"
  else
    cmd_install_deps || { err "Dependency installation failed. Fix and retry."; exit 1; }
    recap "Dependencies" ok "installed"
  fi
  ensure_windows_python
  ensure_sync_daemon_deps_wsl
  echo ""

  step "2/8  Dev environment (distrobox -- required)"
  echo ""
  cmd_setup_distrobox
  recap "Dev container" ok "$DEVTOOLS_DISTROBOX ready"
  echo ""

  step "3/8  Cloning repositories"
  echo ""
  clone_for_features "$features"
  recap "Repositories" ok "cloned"
  echo ""

  if feature_selected bar; then
    ( cd "$DEVTOOLS_DIR" && just bar::lux-install ) \
      || warn "Lux install failed; run 'just bar::lux-install' once the tree settles."
    echo ""
  fi

  step "4/8  Building Docker images"
  echo ""
  if feature_selected teiserver; then
    install_dockerignore
    info "Building Docker images..."
    $COMPOSE build teiserver
    $COMPOSE --profile spads pull spads
    ok "Images built successfully."
    recap "Docker images" ok "built"
  else
    info "Teiserver not selected -- skipping Docker image build."
    recap "Docker images" skip "teiserver not selected"
  fi
  echo ""

  step "5/8  Engine build"
  echo ""
  if feature_selected recoil; then
    if [ -d "$DEVTOOLS_DIR/RecoilEngine/docker-build-v2" ]; then
      local engine_arch engine_os="linux"
      case "$(uname -m)" in
        x86_64)        engine_arch="amd64" ;;
        aarch64|arm64) engine_arch="arm64" ;;
        *)             engine_arch="amd64" ;;
      esac
      is_wsl && engine_os="windows"
      info "Building Recoil engine (${engine_arch}-${engine_os}, this may take a while)..."
      # Via `just engine::build` so the post-success sync.sh mirror-engine hook fires.
      ( cd "$DEVTOOLS_DIR" && just engine::build --arch "$engine_arch" "$engine_os" )
      recap "Engine build" ok "${engine_arch}-${engine_os}"
    else
      warn "Recoil selected but RecoilEngine/docker-build-v2 missing -- clone may have failed."
      recap "Engine build" warn "RecoilEngine missing"
    fi
  else
    info "Recoil not selected -- skipping engine build."
    recap "Engine build" skip "recoil not selected"
  fi
  echo ""

  step "6/8  Symlinks to game directory"
  echo ""
  if [ -z "$game_dir" ]; then
    info "No game directory detected. Set BAR_DATA_DIR to enable linking."
    recap "Symlinks" skip "no game dir"
  elif [ "$do_link" = "yes" ]; then
    local spec feat dir name link_n=0 link_warn=0
    BAR_DATA_DIR="$game_dir"
    for spec in "recoil:RecoilEngine:engine" "chobby:BYAR-Chobby:chobby" "bar:Beyond-All-Reason:bar"; do
      IFS=: read -r feat dir name <<<"$spec"
      feature_selected "$feat" || continue
      if [ -d "$DEVTOOLS_DIR/$dir" ]; then
        cmd_link "$name"
        link_n=$((link_n + 1))
      else
        warn "  ${feat} selected but ${dir} not present -- skipping link (clone may have failed)"
        link_warn=1
      fi
    done
    if [ "$link_warn" -eq 1 ]; then
      recap "Symlinks" warn "${link_n} linked, some missing"
    else
      recap "Symlinks" ok "${link_n} linked"
    fi

    # WSL2: pre-warm the cold-copy seed so the first bar::launch hits the fast incremental path.
    if is_wsl; then
      echo ""
      info "Pre-warming sync state (cold-copy of source pairs to $BAR_DATA_DIR)"
      bash "$DEVTOOLS_DIR/scripts/sync.sh" cold-copy \
        || warn "Pre-warm failed; first 'just bar::launch' will fall back to a full rsync seed."
    fi
  else
    info "Skipping symlinks (declined at configuration step)."
    recap "Symlinks" skip "declined"
  fi
  echo ""

  step "7/8  bar-launch venv (just bar::launch)"
  echo ""
  if is_wsl; then
    ensure_bar_launch_venv_windows && regenerate_bar_launch_cmd_shim
  else
    cmd_setup_bar_launch
  fi
  if [ $? -eq 0 ]; then
    recap "bar-launch venv" ok "ready"
  else
    recap "bar-launch venv" warn "failed -- see output above"
  fi
  echo ""

  step "8/8  Deferred module apply (editor, etc.)"
  echo ""
  apply_deferred_modules
  recap "Editor wiring" ok "applied"
  echo ""

  local feat_n
  feat_n="$(awk -F, '{print NF}' <<<"$features")"
  echo -e "${GREEN}${BOLD}✔ Setup complete${NC} ${DIM}— ${feat_n} feature(s) ready${NC}"
  echo ""
  render_setup_recap
  echo ""
  local f feat_line=""
  for f in ${features//,/ }; do feat_line+="  ${GREEN}✓${NC} ${f}"; done
  echo -e "${feat_line}"
  echo ""
  echo -e "  ${BOLD}Your workspace is ready.${NC} Next steps:"
  echo ""
  if feature_selected teiserver; then
    echo -e "  ${CYAN}Teiserver${NC}"
    echo -e "    ${BOLD}just services::up${NC}             Start Teiserver + PostgreSQL"
    echo -e "    ${BOLD}just services::up spads${NC}       ...and start SPADS autohost"
    echo ""
  fi
  if feature_selected bar; then
    echo -e "  ${CYAN}BAR (game content)${NC}"
    echo -e "    ${BOLD}just bar::launch${NC}              Launch the engine against your local checkout"
    echo -e "    ${BOLD}just services::up lobby${NC}       Launch bar-lobby and connect"
    echo -e "    ${BOLD}just bar::units${NC}               Run busted Lua unit tests"
    echo -e "    ${BOLD}just bar::units-shell${NC}         Drop into an interactive busted shell"
    echo -e "    ${BOLD}just bar::lx-shell${NC}            Drop into an lx shell for package work"
    echo -e "    ${BOLD}just bar::check${NC}               EmmyLua type-check across the repo"
    echo -e "    ${BOLD}just bar::lint${NC}                luacheck (via lux)"
    echo -e "    ${BOLD}just bar::fmt${NC}                 stylua format"
    echo -e "    ${BOLD}just bar::integrations${NC}        Headless integration tests (x86-64 only)"
    echo -e "    ${BOLD}just bar::setup-hooks${NC}         Install the stylua pre-commit hook"
    echo -e "    ${DIM}Edits land in Beyond-All-Reason/ and reflect live via the symlink.${NC}"
    echo ""
  fi
  if feature_selected chobby && ! feature_selected bar; then
    echo -e "  ${CYAN}Chobby${NC}"
    echo -e "    ${BOLD}just services::up lobby${NC}       Launch bar-lobby (loads BYAR-Chobby)"
    echo ""
  fi
  if feature_selected recoil; then
    echo -e "  ${CYAN}Recoil${NC}"
    if is_wsl; then
      echo -e "    ${BOLD}just engine::build windows${NC}    Rebuild the engine"
    else
      echo -e "    ${BOLD}just engine::build linux${NC}      Rebuild the engine"
    fi
    echo ""
  fi
  if feature_selected spads-source; then
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
  require_host

  echo -e "${BOLD}=== BAR Dev Environment Setup ===${NC}"
  echo ""
  check_prerequisites || exit 1

  # Auto-clone the teiserver feature repos if any are missing.
  local missing_teiserver=0
  load_repos_conf
  for i in "${!REPO_DIRS[@]}"; do
    if features_include "${REPO_FEATURES[$i]}" "teiserver" \
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

  # WSL2: the sync-target data dir, not the upstream installer's (which has no Devtools content).
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

    # .sdd suffix required: spring's archive scanner won't register a dir without it.
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

  # WSL2: no symlink -- the sync daemon mirrors source_path to link_path. Just create the target dir.
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

# Load the setup module registry. MUST run after every setup.sh helper is defined.
# shellcheck source=scripts/setup/_lib.sh
source "$DEVTOOLS_DIR/scripts/setup/_lib.sh"
_load_setup_modules
