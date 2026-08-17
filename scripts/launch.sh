#!/usr/bin/env bash
# `just bar::launch` entry point.

set -euo pipefail

# bar.just doesn't export these the way repos.just does; default to match.
: "${REPOS_CONF:=$DEVTOOLS_DIR/repos.conf}"
: "${REPOS_LOCAL:=$DEVTOOLS_DIR/repos.local.conf}"
export REPOS_CONF REPOS_LOCAL

source "$DEVTOOLS_DIR/scripts/common.sh"
source "$DEVTOOLS_DIR/scripts/setup.sh"
source "$DEVTOOLS_DIR/scripts/repos.sh"

require_host

preflight_symlinks() {
  local game_dir
  game_dir="$(detect_game_dir 2>/dev/null)" || true
  if [ -z "$game_dir" ]; then
    warn "Game directory not detected. Set BAR_DATA_DIR or run 'just setup::init' first."
    return 0
  fi

  local missing=()
  [ -L "$game_dir/games/Beyond-All-Reason.sdd" ] || [ -d "$game_dir/games/Beyond-All-Reason.sdd" ] || missing+=("bar")
  [ -L "$game_dir/games/BYAR-Chobby.sdd" ]       || [ -d "$game_dir/games/BYAR-Chobby.sdd" ]       || missing+=("chobby")
  [ -L "$game_dir/engine/local-build" ]          || [ -d "$game_dir/engine/local-build" ]          || missing+=("engine")

  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi

  info "Devtools symlinks missing: ${missing[*]}"
  info "Run: just link::create ${missing[*]}"
  info "(continuing; bar-launch will still work for non-local sources like 'rapid://...:test')"
}

run_linux() {
  local repo_path
  repo_path="$(bar_launch_repo_path)"
  if [ ! -f "$repo_path/bar_launch/__main__.py" ]; then
    err "bar_debug_launcher not found at $repo_path"
    info "Run 'just repos::clone bar' (or 'just setup::init')."
    exit 1
  fi

  preflight_symlinks

  # Inject flags implied by what's checked out; explicit user args always win.
  local injected=()
  local user_args=("$@")
  local game_dir
  game_dir="$(detect_game_dir 2>/dev/null)" || true
  if [ -n "$game_dir" ]; then
    ensure_devmode_marker "$game_dir"
    _apply_managed_springsettings "$game_dir/springsettings.cfg" "${user_args[@]}"
    if [ -e "$game_dir/engine/local-build" ] && ! _has_flag --engine "${user_args[@]}"; then
      injected+=(--engine local-build)
    fi
  fi
  # Strip our own flags so bar-launch doesn't choke on them.
  if _has_flag --debug-gl "${user_args[@]}"; then
    mapfile -d '' user_args < <(_strip_flag --debug-gl "${user_args[@]}")
  fi

  preflight_appimage "${user_args[@]}"

  local where
  where="$(_launch_where "${user_args[@]}")"
  # Strip our placement flags before handing off to bar_launch.
  if _has_flag --host "${user_args[@]}" || _has_flag --container "${user_args[@]}"; then
    mapfile -d '' user_args < <(_strip_flag --host "${user_args[@]}")
    mapfile -d '' user_args < <(_strip_flag --container "${user_args[@]}")
  fi

  # Run from source so repo edits stay live -- no install, no shared
  # ~/.local/bin pipx conflict.
  cd "$repo_path"   # launcher autodetect anchors on cwd
  if [ "$where" = "host" ]; then
    # Host is the default: a host-run launcher execs the engine directly.
    info "Running on host: bar_launch ${injected[*]:-} ${user_args[*]:-}"
    exec env PYTHONPATH="$repo_path" python3 -m bar_launch "${injected[@]}" "${user_args[@]}"
  fi

  # Container: bar-dev's Fedora Tk gives the GUI real fonts + antialiasing on
  # hosts whose python3 has no usable Tk. The engine is launched back on the
  # host by bar_launch via distrobox-host-exec -> host-spawn, which rides on
  # flatpak's session helper (org.freedesktop.Flatpak on the session bus): a
  # host without flatpak gets a bare "exit 127". Say so before it happens.
  local box="${DEVTOOLS_DISTROBOX:-bar-dev}"
  if ! command -v flatpak >/dev/null 2>&1; then
    warn "flatpak is not installed on this host: the container->host engine bridge"
    warn "(distrobox-host-exec -> host-spawn -> flatpak-session-helper) will fail with exit 127."
    warn "Either install flatpak, or run the launcher on the host: just bar::launch --host ..."
    warn "  (host GUI needs: python3 with tkinter, six, requests)"
  fi
  info "Running in ${box}: bar_launch ${injected[*]:-} ${user_args[*]:-}"
  exec distrobox enter "$box" -- \
    env PYTHONPATH="$repo_path" python3 -m bar_launch "${injected[@]}" "${user_args[@]}"
}

# Where the launcher process runs: "host" or "container".
#
# Host by default. Nothing about a headless launch needs the container, and a
# host-run launcher execs the compiled engine directly -- no
# distrobox-host-exec -> host-spawn -> flatpak-session-helper bridge, which is
# an unrelated flatpak dependency and fails with a bare 127 where flatpak isn't
# installed. The container is only worth it for the GUI on a host whose
# python3 can't import tkinter (bar-dev's Fedora Tk has real fonts).
#
# Override: --host / --container on the command line, or BAR_LAUNCH_IN=host|container
# in .env. Explicit choices are honored even if the host is missing modules
# (you'll get python's ImportError, which names what to install).
_launch_where() {
  if _has_flag --host "$@"; then echo host; return; fi
  if _has_flag --container "$@"; then echo container; return; fi
  case "${BAR_LAUNCH_IN:-}" in
    host|container) echo "$BAR_LAUNCH_IN"; return ;;
  esac
  local headless=0
  if _has_flag --headless "$@" || _has_flag --no-gui "$@" || _has_flag --print-cmd "$@"; then
    headless=1
  fi
  if [ "$headless" = 1 ]; then
    # slpp (the modinfo/cache Lua parser) needs six; that's the whole dependency list.
    if _host_python_has six; then echo host; return; fi
    info "host python3 lacks 'six' (pip install six) -- running headless in ${DEVTOOLS_DISTROBOX:-bar-dev}"
    echo container; return
  fi
  if _host_python_has tkinter six requests; then echo host; return; fi
  info "host python3 lacks tkinter/six/requests -- running the GUI in ${DEVTOOLS_DISTROBOX:-bar-dev}"
  info "  (to run it on the host: install python3-tk, then pip install six requests)"
  echo container
}

# True if the host python3 can import every named module.
_host_python_has() {
  command -v python3 >/dev/null 2>&1 || return 1
  local mods="" m
  for m in "$@"; do mods+="import $m; "; done
  python3 -c "$mods" >/dev/null 2>&1
}

# Matches both "--engine X" and "--engine=X" forms.
_has_flag() {
  local needle="$1"
  shift
  local arg
  for arg in "$@"; do
    if [ "$arg" = "$needle" ] || [[ "$arg" == "$needle="* ]]; then
      return 0
    fi
  done
  return 1
}

# Echo a flag's value; "--play X" or "--play=X", last occurrence wins.
_flag_value() {
  local needle="$1"; shift
  local prev="" arg out=""
  for arg in "$@"; do
    if [ "$prev" = "$needle" ]; then
      out="$arg"
    elif [[ "$arg" == "$needle="* ]]; then
      out="${arg#*=}"
    fi
    prev="$arg"
  done
  printf '%s' "$out"
}

# Drop a boolean flag from "$@", echoing the rest NUL-separated for mapfile.
_strip_flag() {
  local needle="$1"; shift
  local arg
  for arg in "$@"; do
    if [ "$arg" = "$needle" ]; then continue; fi
    printf '%s\0' "$arg"
  done
}

# True if this launch boots via the AppImage launcher (so it needs an AppImage).
# Mirrors bar_launch: boot = --boot or default (launcher for chobby, else engine).
_launch_uses_appimage() {
  _has_flag --print-cmd "$@" && return 1
  _has_flag --launcher-binary "$@" && return 1   # explicit binary; BAR_APPIMAGE_PATH unused
  if _has_flag --boot "$@"; then
    [ "$(_flag_value --boot "$@")" = "launcher" ]; return
  fi
  if _has_flag --play "$@"; then
    [ "$(_flag_value --play "$@")" = "chobby" ]; return
  fi
  # No --play: headless needs --play (bar-launch errors on its own); GUI may
  # pick a launcher boot, so assume it could need the AppImage.
  _has_flag --no-gui "$@" && return 1
  _has_flag --headless "$@" && return 1
  return 0
}

# Only when this launch will actually use the AppImage: ensure one resolves,
# re-prompting interactively or failing with guidance instead of a deep traceback.
preflight_appimage() {
  _launch_uses_appimage "$@" || return 0
  bar_appimage_resolves && return 0

  if ! _has_flag --play "$@" && ! _has_flag --boot "$@"; then
    # Plain GUI launch: only *might* need the AppImage. The GUI explains a
    # missing one in its command panel and Boot = engine works without it,
    # so don't block someone who just wants to run their compiled engine.
    info "No Beyond-All-Reason AppImage configured: in the GUI, Boot = launcher will say so;"
    info "  Boot = engine needs none. To set one: just setup::reconfigure"
    info "  (or BAR_APPIMAGE_PATH in $DEVTOOLS_DIR/.env)"
    return 0
  fi

  if [ -t 0 ]; then
    warn "This launch boots via the AppImage launcher, but no Beyond-All-Reason AppImage resolves."
    ensure_bar_appimage_path_set || true
    local p; p="$(read_env_key BAR_APPIMAGE_PATH)"
    [ -n "$p" ] && export BAR_APPIMAGE_PATH="${p/#\~/$HOME}"
    bar_appimage_resolves && return 0
    warn "Still no AppImage configured -- launcher boot will likely fail."
    return 0
  fi

  err "This launch needs the Beyond-All-Reason AppImage but BAR_APPIMAGE_PATH isn't set/resolvable."
  info "Set it: just setup::reconfigure   (or set BAR_APPIMAGE_PATH in $DEVTOOLS_DIR/.env)"
  info "Engine-direct boots (--boot engine / --play bar) don't need it."
  exit 1
}

# springsettings.cfg keys this launcher owns. Row: <flag> <key> <on> <off>.
# Every launch resets each key, so a prior launch can't leak settings.
_MANAGED_SPRINGSETTINGS=(
  "--debug-gl  DebugGL   1  0"
  "--debug-gl  LogFlush  1  0"
)

# Gated on ALLOW_SPRINGSETTINGS_MOD; default off, never touches the cfg
# unless the user opted in. Without the opt-in, warn once per ignored flag.
_apply_managed_springsettings() {
  local cfg="$1"; shift

  local opt_in="${ALLOW_SPRINGSETTINGS_MOD:-0}"
  case "$opt_in" in
    1|true|TRUE|yes|YES) ;;
    *)
      local entry flag _rest seen=()
      for entry in "${_MANAGED_SPRINGSETTINGS[@]}"; do
        read -r flag _rest <<<"$entry"
        if _has_flag "$flag" "$@"; then
          local already=0 s
          for s in "${seen[@]}"; do [ "$s" = "$flag" ] && already=1 && break; done
          if [ "$already" = "0" ]; then
            warn "$flag was ignored: ALLOW_SPRINGSETTINGS_MOD is not enabled"
            info "  This launcher does not modify springsettings.cfg by default."
            info "  To enable: re-run 'just setup::init' and opt in, or set"
            info "    ALLOW_SPRINGSETTINGS_MOD=1"
            info "  in $DEVTOOLS_DIR/.env"
            seen+=("$flag")
          fi
        fi
      done
      return 0
      ;;
  esac

  if [ -z "$cfg" ]; then
    local entry flag _rest
    for entry in "${_MANAGED_SPRINGSETTINGS[@]}"; do
      read -r flag _rest <<<"$entry"
      if _has_flag "$flag" "$@"; then
        warn "$flag requested but no springsettings.cfg path resolved; skipping"
      fi
    done
    return 0
  fi

  local -A logged_on=()
  local entry flag key on_v off_v
  for entry in "${_MANAGED_SPRINGSETTINGS[@]}"; do
    read -r flag key on_v off_v <<<"$entry"
    if _has_flag "$flag" "$@"; then
      if [ -z "${logged_on[$flag]:-}" ]; then
        info "$flag: applying managed springsettings in $cfg"
        logged_on[$flag]=1
      fi
      springsettings_set "$cfg" "$key" "$on_v" \
        || warn "Could not set $key=$on_v (override for $flag)"
    else
      springsettings_set "$cfg" "$key" "$off_v" >/dev/null 2>&1 || true
    fi
  done
}

run_wsl() {
  if [ -z "${BAR_DATA_DIR:-}" ]; then
    err "BAR_DATA_DIR not set. Run 'just setup::init' on WSL2 first."
    exit 1
  fi

  ensure_devmode_marker "$BAR_DATA_DIR"
  _apply_managed_springsettings "$BAR_DATA_DIR/springsettings.cfg" "$@"

  # Strip --debug-gl: the Windows-side launcher would choke on it.
  local launch_args=()
  if _has_flag --debug-gl "$@"; then
    mapfile -d '' launch_args < <(_strip_flag --debug-gl "$@")
  else
    launch_args=("$@")
  fi

  local debug_dir="${BAR_DEBUG_DIR:-$(bar_debug_dir_get)}"
  if [ -z "$debug_dir" ]; then
    err "BAR_DEBUG_DIR not set -- run 'just bar::regen-shim' or 'just setup::init' first."
    exit 1
  fi

  local shim_wsl="$debug_dir/bin/bar-launch.cmd"
  if [ ! -f "$shim_wsl" ]; then
    err "Launcher shim missing at $shim_wsl"
    info "Regenerate: just bar::regen-shim"
    exit 1
  fi

  # --wait-ready: don't launch into a half-mirrored data dir.
  bash "$DEVTOOLS_DIR/scripts/sync.sh" start --wait-ready \
    || { err "sync daemon failed to start (see logs: just bar::sync-logs)"; exit 1; }

  local shim_win
  shim_win="$(wslpath -w "$shim_wsl")"

  # Capture the detached launcher's output -- else a Windows-side crash vanishes.
  local launch_log="$debug_dir/.bar-launch/launcher.log"
  mkdir -p "$(dirname "$launch_log")"
  : >"$launch_log"

  # printf, not info: `echo -e` interprets \b in ...\bin\... as backspace.
  printf '\033[0;34m[info]\033[0m  Launching detached: %s %s\n' "$shim_win" "${launch_args[*]}"
  printf '\033[0;34m[info]\033[0m  logs:  just bar::log -- -F      (engine infolog)\n'
  printf '\033[0;34m[info]\033[0m         just bar::sync-logs            (cold-copy log)\n'
  printf '\033[0;34m[info]\033[0m         %s   (launcher stdout/stderr)\n' "$launch_log"

  # Plain `cmd.exe /c` -- `start "" /B` gets its "" double-escaped by WSL2
  # interop. cd /mnt/c gives cmd.exe a drive-letter cwd (avoids UNC warning).
  ( cd /mnt/c && nohup cmd.exe /c "$shim_win" "${launch_args[@]}" </dev/null >"$launch_log" 2>&1 & )
  return 0
}

stop_wsl() {
  if ! command -v cmd.exe &>/dev/null; then
    err "cmd.exe interop unavailable -- can't stop Windows processes from here"
    return 1
  fi

  step "Stopping BAR processes"
  local killed_any=0
  local proc
  for proc in spring.exe Beyond-All-Reason.exe; do
    local out rc
    out="$(cmd.exe /c "taskkill /F /IM $proc /T" 2>&1)" || rc=$? && rc=${rc:-0}
    if [ "$rc" -eq 0 ]; then
      info "  killed: $proc"
      killed_any=1
    fi
  done

  # CIM, not wmic (gone in 24H2+); taskkill, not Stop-Process (under-kills).
  local pid_cmd='Get-CimInstance Win32_Process -Filter "Name='\''python.exe'\''" | Where-Object { $_.CommandLine -like "*bar_launch*" } | Select-Object -ExpandProperty ProcessId'
  local pids
  pids="$(powershell.exe -NoProfile -Command "$pid_cmd" 2>/dev/null | tr -d '\r')"
  if [ -n "$pids" ]; then
    local pid
    while IFS= read -r pid; do
      [ -z "$pid" ] && continue
      local rc=0
      cmd.exe /c "taskkill /F /T /PID $pid" >/dev/null 2>&1 || rc=$?
      if [ "$rc" = "0" ]; then
        info "  killed: python.exe (PID $pid, bar_launch)"
        killed_any=1
      else
        warn "  taskkill /PID $pid (bar_launch) returned $rc -- process may still be running"
      fi
    done <<<"$pids"

    # CIM cache can lag taskkill -- brief sleep before re-query.
    sleep 0.3
    local survivors
    # awk 'NF' not grep -v '^$': grep returns 1 on no matches and trips set -e.
    survivors="$(powershell.exe -NoProfile -Command "$pid_cmd" 2>/dev/null | tr -d '\r' | awk 'NF')"
    if [ -n "$survivors" ]; then
      warn "bar_launch python.exe survivors after kill:"
      while IFS= read -r pid; do
        [ -n "$pid" ] && warn "  PID $pid still running"
      done <<<"$survivors"
      warn "  Likely cause: process running as a different user, or a"
      warn "  protection policy is blocking taskkill. Try from an elevated"
      warn "  PowerShell:  taskkill /F /T /PID <pid>"
    fi
  fi

  local debug_dir="${BAR_DEBUG_DIR:-$(bar_debug_dir_get)}"
  if [ -n "$debug_dir" ] \
     && [ -f "$debug_dir/.bar-launch/sync.pid" ]; then
    bash "$DEVTOOLS_DIR/scripts/sync.sh" stop \
      && killed_any=1 \
      || warn "sync daemon stop returned non-zero (see $debug_dir/.bar-launch/sync.log)"
  fi

  if [ "$killed_any" = "0" ]; then
    info "no BAR processes were running"
  else
    ok "BAR processes stopped"
  fi
}

stop_linux() {
  step "Stopping BAR processes"
  local killed_any=0

  # -f matches the full cmdline so we don't hit unrelated Pythons.
  local pids
  pids="$(pgrep -f 'python.* -m bar_launch' 2>/dev/null | awk 'NF' || true)"
  if [ -n "$pids" ]; then
    while IFS= read -r pid; do
      [ -z "$pid" ] && continue
      if kill -TERM "$pid" 2>/dev/null; then
        info "  killed: python -m bar_launch (PID $pid)"
        killed_any=1
      fi
    done <<<"$pids"
  fi

  # Scope spring kills to binaries running out of our game dir.
  local game_dir
  game_dir="$(detect_game_dir 2>/dev/null)" || true
  if [ -n "$game_dir" ]; then
    local spring_pids
    spring_pids="$(pgrep -x 'spring|spring-headless|spring-dedicated' 2>/dev/null | awk 'NF' || true)"
    if [ -n "$spring_pids" ]; then
      while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        local exe
        exe="$(readlink "/proc/$pid/exe" 2>/dev/null)" || continue
        case "$exe" in
          "$game_dir"/*)
            if kill -TERM "$pid" 2>/dev/null; then
              info "  killed: $(basename "$exe") (PID $pid, $game_dir)"
              killed_any=1
            fi
            ;;
        esac
      done <<<"$spring_pids"
    fi
  fi

  # Anything alive after a brief grace period gets SIGKILL.
  sleep 0.3
  local python_bar_launch_survivors
  python_bar_launch_survivors="$(pgrep -f 'python.* -m bar_launch' 2>/dev/null | awk 'NF' || true)"
  if [ -n "$python_bar_launch_survivors" ]; then
    while IFS= read -r pid; do
      [ -z "$pid" ] && continue
      if kill -KILL "$pid" 2>/dev/null; then
        warn "  SIGKILL'd surviving python -m bar_launch (PID $pid)"
      else
        warn "  PID $pid (bar_launch) survived SIGTERM and SIGKILL failed"
      fi
    done <<<"$python_bar_launch_survivors"
  fi

  if [ "$killed_any" = "0" ]; then
    info "no BAR processes were running"
  else
    ok "BAR processes stopped"
  fi
}

case "${BAR_LAUNCH_MODE:-launch}" in
  stop)
    if is_wsl; then stop_wsl; else stop_linux; fi
    exit $?
    ;;
  launch|*)
    if is_wsl; then
      run_wsl "$@"
      exit $?
    else
      run_linux "$@"
    fi
    ;;
esac
