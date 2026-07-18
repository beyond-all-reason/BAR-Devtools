#!/usr/bin/env bash
# WSL2 ↔ Windows helpers: path conversion, Windows-Python detection, BAR install
# resolution, and the Windows launcher venv/shim. Source common.sh before this file.
# All entry points are is_wsl-gated and return 0 on Linux.

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

# Normalize a user-entered path (WSL or Windows form) to a WSL path.
_path_input_to_wsl() {
  local response="$1"
  case "$response" in
    /mnt/*|/home/*|/root/*) printf '%s' "${response/#\~/$HOME}" ;;
    *)
      local converted
      converted="$(_to_wsl_path "$response")"
      if [ -z "$converted" ] || [ "$converted" = "$response" ]; then
        warn "Couldn't convert '$response' via wslpath -- saving as-is."
        printf '%s' "$response"
      else
        printf '%s' "$converted"
      fi
      ;;
  esac
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

# Echo a real Windows Python (py.exe/python.exe), scanning standard install
# dirs when the WSL PATH hasn't re-imported a freshly-installed one yet (winget
# installs aren't visible until a new shell). Echoes nothing if none found.
_find_windows_python() {
  local p
  p="$(command -v py.exe 2>/dev/null || true)"
  _is_real_windows_python "$p" && { echo "$p"; return 0; }
  p="$(command -v python.exe 2>/dev/null || true)"
  _is_real_windows_python "$p" && { echo "$p"; return 0; }

  local localappdata base d
  localappdata="$(cd /mnt/c 2>/dev/null && cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r')"
  local -a bases=("/mnt/c/Program Files" "/mnt/c/Program Files (x86)")
  [ -n "$localappdata" ] && bases+=("$(wslpath -u "$localappdata" 2>/dev/null)/Programs/Python")
  for base in "${bases[@]}"; do
    [ -d "$base" ] || continue
    for d in "$base"/Python3*/python.exe; do
      [ -f "$d" ] && { echo "$d"; return 0; }
    done
  done
  [ -f /mnt/c/Windows/py.exe ] && { echo /mnt/c/Windows/py.exe; return 0; }
  return 1
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

# Best-effort: locate a BAR install on any drive via the installer's Uninstall
# registry record. Echoes the WSL path to its data dir, or nothing.
_detect_bar_install_win() {
  is_wsl || return 0
  command -v reg.exe &>/dev/null || return 0
  command -v wslpath &>/dev/null || return 0
  local hive key dump loc loc_wsl
  for hive in \
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall' \
    'HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall' \
    'HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; do
    key="$(reg.exe query "$hive" /s /v DisplayName 2>/dev/null | tr -d '\r' \
      | grep -iB1 'REG_SZ[[:space:]]*Beyond-All-Reason' | grep -i '^HKEY' | head -n1)"
    [ -n "$key" ] || continue
    dump="$(reg.exe query "$key" 2>/dev/null | tr -d '\r')"
    # All-users installs omit InstallLocation; recover the dir from DisplayIcon
    # (exe path with a ,N icon suffix) or the quoted UninstallString.
    loc="$(printf '%s\n' "$dump" | sed -n 's/.*InstallLocation[[:space:]]*REG_SZ[[:space:]]*//p' | head -n1)"
    [ -z "$loc" ] && loc="$(printf '%s\n' "$dump" | sed -n 's/.*DisplayIcon[[:space:]]*REG_SZ[[:space:]]*//p' | head -n1 | sed 's/,[0-9]*$//; s/\\[^\\]*$//')"
    [ -z "$loc" ] && loc="$(printf '%s\n' "$dump" | sed -n 's/.*UninstallString[[:space:]]*REG_SZ[[:space:]]*//p' | head -n1 | sed 's/^"//; s/".*$//; s/\\[^\\]*$//')"
    loc="${loc%\\}"
    [ -n "$loc" ] || continue
    loc_wsl="$(wslpath -u "$loc" 2>/dev/null)" || continue
    [ -e "$loc_wsl/Beyond-All-Reason.exe" ] && { echo "$loc_wsl/data"; return 0; }
  done
}

# Default to the BAR install's own data dir, wherever it lives: the standard
# per-user location, else the installer's registry record. No install found ->
# no default (prompt), never a guess we'd sync into the wrong place.
_default_bar_data_dir() {
  is_wsl || return 0
  command -v cmd.exe &>/dev/null || return 0
  command -v wslpath &>/dev/null || return 0
  local localappdata
  localappdata="$(cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r\n')"
  case "$localappdata" in
    ''|*%LOCALAPPDATA%*) ;;
    *)
      local wsl_path install
      wsl_path="$(wslpath -u "$localappdata" 2>/dev/null)"
      install="$wsl_path/Programs/Beyond-All-Reason"
      if [ -n "$wsl_path" ] && [ -e "$install/Beyond-All-Reason.exe" ]; then
        echo "$install/data"; return 0
      fi
      ;;
  esac
  _detect_bar_install_win
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

# BAR_DEBUG_DIR: BAR-Devtools-generated launcher runtime (venv, build staging, shim,
# sync state). Kept out of the game's install dir so we never write into Program Files.
bar_debug_dir_get() {
  local env_file="$DEVTOOLS_DIR/.env"
  if [ -f "$env_file" ]; then
    local val
    val="$(grep -E '^BAR_DEBUG_DIR=' "$env_file" 2>/dev/null | tail -n1 | cut -d= -f2-)"
    if [ -n "$val" ]; then
      val="${val%\"}"; val="${val#\"}"
      echo "$val"
      return 0
    fi
  fi
  echo "${BAR_DEBUG_DIR:-}"
}

# Resolve BAR_DEBUG_DIR (default %LOCALAPPDATA%\bar_debug_launcher), persist, mkdir. WSL-only.
ensure_bar_debug_dir() {
  is_wsl || return 0

  local env_file="$DEVTOOLS_DIR/.env"
  touch "$env_file"

  local current
  current="$(bar_debug_dir_get)"
  if [ -n "$current" ] && [ -z "${BAR_RESET_CONFIG:-}" ]; then
    info "BAR_DEBUG_DIR already set: $current"
  else
    local default_path="$current"
    if [ -z "$default_path" ]; then
      local localappdata
      localappdata="$(cd /mnt/c 2>/dev/null && cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r')"
      if [ -z "$localappdata" ]; then
        err "Could not resolve %LOCALAPPDATA% -- set BAR_DEBUG_DIR in .env (a /mnt/<drive> NTFS path) and re-run."
        return 1
      fi
      default_path="$(wslpath -u "$localappdata")/bar_debug_launcher"
    fi

    info "Where we install bar_debug_launcher for you (recommended: accept the default by pressing Enter)."

    local response=""
    [ -t 0 ] && read -rp "BAR debug dir [$(_to_windows_path "$default_path")]: " response
    if [ -z "$response" ]; then
      current="$default_path"
    else
      current="$(_path_input_to_wsl "$response")"
    fi
  fi

  if grep -q '^BAR_DEBUG_DIR=' "$env_file"; then
    sed -i "s|^BAR_DEBUG_DIR=.*|BAR_DEBUG_DIR=\"$current\"|" "$env_file"
  else
    printf 'BAR_DEBUG_DIR="%s"\n' "$current" >> "$env_file"
    ok "Added BAR_DEBUG_DIR=$current to .env"
  fi

  local sub
  for sub in bin .bar-launch; do
    mkdir -p "$current/$sub" 2>/dev/null || {
      err "Couldn't mkdir $current/$sub -- check that the path is reachable from WSL."
      return 1
    }
  done

  ok "BAR debug dir ready: $current"

  export BAR_DEBUG_DIR="$current"
}

# Persist BAR_DATA_DIR in WSL path form; the Windows shim converts it. WSL-only.
ensure_bar_data_dir() {
  is_wsl || return 0

  local env_file="$DEVTOOLS_DIR/.env"
  touch "$env_file"

  local current
  current="$(bar_data_dir_get)"
  # The old BAR-DevSync fallback decoupled the data dir from the install and
  # broke launcher boot; treat it as unset so we re-resolve the real BAR dir.
  case "$current" in
    *BAR-DevSync|*BAR-DevSync/)
      warn "BAR_DATA_DIR was a standalone sync dir ($current) -- re-resolving the real BAR data dir."
      current=""
      ;;
  esac
  if [ -n "$current" ] && [ -z "${BAR_RESET_CONFIG:-}" ]; then
    info "BAR_DATA_DIR already set: $current"
  else
    info "Your BAR install's data dir (e.g. %LOCALAPPDATA%\\Programs\\Beyond-All-Reason\\data\\)."

    local default_path="$current"
    [ -z "$default_path" ] && default_path="$(_default_bar_data_dir)"

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
        err "No BAR_DATA_DIR provided and no BAR install detected."
        info "Set it to your install's data dir, e.g. in BAR-Devtools/.env:"
        info "  BAR_DATA_DIR=/mnt/c/Users/<you>/AppData/Local/Programs/Beyond-All-Reason/data"
        return 1
      fi
      current="$default_path"
    else
      current="$(_path_input_to_wsl "$response")"
    fi

  fi

  # Persist double-quoted: a spaced path (e.g. "Program Files") otherwise breaks
  # just's dotenv parser. WSL path = forward slashes, so no backslash-escape worry.
  if grep -q '^BAR_DATA_DIR=' "$env_file"; then
    sed -i "s|^BAR_DATA_DIR=.*|BAR_DATA_DIR=\"$current\"|" "$env_file"
  else
    printf 'BAR_DATA_DIR="%s"\n' "$current" >> "$env_file"
    ok "Added BAR_DATA_DIR=$current to .env"
  fi

  local sub
  for sub in engine/local-build games/Beyond-All-Reason.sdd games/BYAR-Chobby.sdd; do
    mkdir -p "$current/$sub" 2>/dev/null || {
      err "Couldn't mkdir $current/$sub -- check that the path is reachable from WSL."
      return 1
    }
  done

  ensure_devmode_marker "$current"

  ok "BAR data dir ready: $current"

  export BAR_DATA_DIR="$current"
}

# Build a Windows venv (not WSL): the launcher spawns the native Windows engine, avoiding a WSL hop.
ensure_bar_launch_venv_windows() {
  is_wsl || return 0

  local debug_dir_wsl="${BAR_DEBUG_DIR:-$(bar_debug_dir_get)}"
  if [ -z "$debug_dir_wsl" ]; then
    warn "BAR_DEBUG_DIR not set -- run 'just bar::regen-shim' or 'just setup::init' first."
    return 1
  fi

  local py_path
  py_path="$(_find_windows_python)"
  if [ -z "$py_path" ]; then
    warn "No real Windows Python found -- skipping venv bootstrap."
    info "Install Windows Python (e.g. 'winget install Python.Python.3.12'), then re-run 'just setup::init'."
    return 1
  fi

  local venv_wsl="$debug_dir_wsl/.venv"
  local venv_python_wsl="$venv_wsl/Scripts/python.exe"

  if [ ! -x "$venv_python_wsl" ] && [ ! -f "$venv_python_wsl" ]; then
    step "Creating Windows venv at $venv_wsl"
    local -a pyargs=()
    case "$py_path" in *py.exe) pyargs=(-3) ;; esac   # -3 is a py-launcher flag; python.exe rejects it
    "$py_path" "${pyargs[@]}" -m venv "$(_to_windows_path "$venv_wsl")" \
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
  # Editable, not wheel: the launcher leans on undeclared root modules (e.g.
  # script.py absent from py-modules) that only resolve with its dir on sys.path.
  # pip builds in-tree, but the source is on \\wsl.localhost\... (9p) where Windows
  # python can't utime egg-info, so install -e from a persistent NTFS copy. The
  # editable pointer references the copy; re-run regen-shim after launcher edits.
  local stage_wsl="$debug_dir_wsl/.bar-launch-src"
  mkdir -p "$stage_wsl"
  rsync -a --delete --exclude='.git' --exclude='*.egg-info' --exclude=build --exclude=dist \
    "$repo_path"/ "$stage_wsl"/ \
    || { err "Failed to stage bar_debug_launcher source"; return 1; }
  "$venv_python_wsl" -m pip install --upgrade pip --quiet \
    || warn "pip self-upgrade failed; continuing"
  "$venv_python_wsl" -m pip install --quiet --editable "$(_to_windows_path "$stage_wsl")" \
    || { err "pip install bar_debug_launcher failed"; return 1; }

  ok "Windows venv ready: $venv_wsl"
  export BAR_LAUNCH_VENV="$venv_wsl"
}

# Generate <BAR_DEBUG_DIR>/bin/bar-launch.cmd with absolute Windows paths baked in.
regenerate_bar_launch_cmd_shim() {
  is_wsl || return 0

  local data_dir_wsl="${BAR_DATA_DIR:-$(bar_data_dir_get)}"
  if [ -z "$data_dir_wsl" ]; then
    err "BAR_DATA_DIR not set -- run 'just setup::init' on WSL first."
    return 1
  fi

  local debug_dir_wsl="${BAR_DEBUG_DIR:-$(bar_debug_dir_get)}"
  if [ -z "$debug_dir_wsl" ]; then
    err "BAR_DEBUG_DIR not set -- run 'just setup::init' on WSL first."
    return 1
  fi

  local venv_python_wsl="$debug_dir_wsl/.venv/Scripts/python.exe"
  if [ ! -f "$venv_python_wsl" ]; then
    err "Windows venv python not found at $venv_python_wsl"
    info "Run 'just setup::init' to create it."
    return 1
  fi

  local shim_wsl="$debug_dir_wsl/bin/bar-launch.cmd"
  mkdir -p "$(dirname "$shim_wsl")"

  local venv_python_win data_dir_win bar_install_win
  venv_python_win="$(_to_windows_path "$venv_python_wsl")"
  data_dir_win="$(_to_windows_path "$data_dir_wsl")"
  # The launcher .exe lives in the install root (parent of the data dir),
  # wherever BAR is installed; pass it so launcher boots resolve on any drive.
  bar_install_win="$(_to_windows_path "$(dirname "$data_dir_wsl")")"

  cat > "$shim_wsl" <<EOF
@echo off
REM Generated by BAR-Devtools setup. Edit via: just bar::regen-shim
"$venv_python_win" -m bar_launch --bar-install "$bar_install_win" --data-dir "$data_dir_win" %*
EOF
  sed -i 's/$/\r/' "$shim_wsl"

  ok "Generated $shim_wsl"
}
