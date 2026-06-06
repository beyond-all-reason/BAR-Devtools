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
source "$DEVTOOLS_DIR/scripts/chobby-channel.sh"

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

# Only relevant when chobby drives game selection and a local BAR.sdd exists.
preflight_chobby_channel() {
  local data_dir="$1"; shift
  [ -n "$data_dir" ] || return 0

  if _has_flag --play "$@"; then
    local play_val
    play_val="$(_flag_value --play "$@")"
    [ "$play_val" = "chobby" ] || return 0
  fi

  if [ ! -L "$data_dir/games/Beyond-All-Reason.sdd" ] && \
     [ ! -d "$data_dir/games/Beyond-All-Reason.sdd" ]; then
    return 0
  fi

  local desired="${BAR_CHOBBY_CHANNEL:-}"
  if [ -z "$desired" ]; then
    desired="$(read_env_key BAR_CHOBBY_CHANNEL 2>/dev/null || true)"
  fi

  local cfg_current widget_current
  cfg_current="$(_chobby_game_field "$data_dir/chobby_config.json")"
  widget_current="$(_chobby_widget_game_field "$data_dir")"
  # IGL_data.lua's saved value overrides chobby_config.json's default.
  local effective="${widget_current:-$cfg_current}"

  if [ "$desired" = "byar-dev" ]; then
    if [ "$cfg_current" = "byar-dev" ] && \
       { [ -z "$widget_current" ] || [ "$widget_current" = "byar-dev" ]; }; then
      return 0
    fi

    warn "Chobby channel drifted from byar-dev:"
    warn "  chobby_config.json:   ${cfg_current:-<unset>}"
    warn "  IGL_data.lua widget:  ${widget_current:-<unset>}  <-- this is what the dropdown will use"
    warn "Your local Beyond-All-Reason.sdd edits will NOT load until this is fixed."

    if [ ! -t 0 ]; then
      warn "(non-interactive shell -- not prompting; run 'just bar::dev-mode' to fix)"
      return 0
    fi
    local ans
    read -rp "Reset Chobby channel to dev mode (byar-dev) now? [Y/n] " ans
    if [ -z "$ans" ] || [[ "$ans" =~ ^[Yy] ]]; then
      set_chobby_channel "$data_dir" "byar-dev"
      ok "Chobby channel reset to byar-dev"
    else
      warn "Continuing without fix; Chobby will load the rapid build for this run."
    fi
    return 0
  fi

  warn "bar::launch found a local Beyond-All-Reason.sdd but Chobby channel = '${effective:-<unset>}', NOT byar-dev."
  warn "Your local edits will NOT load and dev-mode is OFF."
  warn "Fix: just bar::dev-mode   (or set BAR_CHOBBY_CHANNEL=byar-dev in .env)"
}

run_linux() {
  if ! command -v bar-launch &>/dev/null; then
    err "bar-launch not on PATH"
    info "Run 'just setup::init' (pipx-installs the launcher), or run 'pipx ensurepath' if it's already installed."
    exit 1
  fi
  local repo_path
  repo_path="$(bar_launch_repo_path)"

  # Editable installs pick up .py edits, but a new pinned dep needs a reinstall.
  local marker="${XDG_STATE_HOME:-$HOME/.local/state}/bar-devtools/bar-launch-installed"
  local pyproject="$repo_path/pyproject.toml"
  if [ -f "$pyproject" ] && [ -f "$marker" ] && [ "$pyproject" -nt "$marker" ]; then
    info "$(basename "$repo_path")/pyproject.toml is newer than the bar-launch install -- reinstalling"
    ensure_bar_launch_installed "$repo_path" || exit 1
  fi

  preflight_symlinks

  # Inject flags implied by what's checked out; explicit user args always win.
  local injected=()
  local user_args=("$@")
  local game_dir
  game_dir="$(detect_game_dir 2>/dev/null)" || true
  if [ -n "$game_dir" ]; then
    ensure_devmode_marker "$game_dir"
    preflight_chobby_channel "$game_dir" "${user_args[@]}"
    _apply_managed_springsettings "$game_dir/springsettings.cfg" "${user_args[@]}"
    if [ -e "$game_dir/engine/local-build" ] && ! _has_flag --engine "${user_args[@]}"; then
      injected+=(--engine local-build)
    fi
  fi
  # Strip our own flags so bar-launch doesn't choke on them.
  if _has_flag --debug-gl "${user_args[@]}"; then
    mapfile -d '' user_args < <(_strip_flag --debug-gl "${user_args[@]}")
  fi

  # Launcher autodetect anchors on cwd; point it at the managed checkout.
  cd "$repo_path"

  info "Running: bar-launch ${injected[*]:-} ${user_args[*]:-}"
  exec bar-launch "${injected[@]}" "${user_args[@]}"
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
  preflight_chobby_channel "$BAR_DATA_DIR" "$@"
  _apply_managed_springsettings "$BAR_DATA_DIR/springsettings.cfg" "$@"

  # Strip --debug-gl: the Windows-side launcher would choke on it.
  local launch_args=()
  if _has_flag --debug-gl "$@"; then
    mapfile -d '' launch_args < <(_strip_flag --debug-gl "$@")
  else
    launch_args=("$@")
  fi

  local shim_wsl="$BAR_DATA_DIR/bin/bar-launch.cmd"
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

  # printf, not info: `echo -e` interprets \b in ...\bin\... as backspace.
  printf '\033[0;34m[info]\033[0m  Launching detached: %s %s\n' "$shim_win" "${launch_args[*]}"
  printf '\033[0;34m[info]\033[0m  logs:  just bar::log -- -F      (engine infolog)\n'
  printf '\033[0;34m[info]\033[0m         just bar::sync-logs            (cold-copy log)\n'

  # Plain `cmd.exe /c` -- `start "" /B` gets its "" double-escaped by WSL2
  # interop. cd /mnt/c gives cmd.exe a drive-letter cwd (avoids UNC warning).
  ( cd /mnt/c && nohup cmd.exe /c "$shim_win" "${launch_args[@]}" </dev/null >/dev/null 2>&1 & )
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

  if [ -n "${BAR_DATA_DIR:-}" ] \
     && [ -f "$BAR_DATA_DIR/.bar-launch/sync.pid" ]; then
    bash "$DEVTOOLS_DIR/scripts/sync.sh" stop \
      && killed_any=1 \
      || warn "sync daemon stop returned non-zero (see $BAR_DATA_DIR/.bar-launch/sync.log)"
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
  pids="$(pgrep -f 'python.* -m bar_launch' 2>/dev/null | awk 'NF')"
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
    spring_pids="$(pgrep -x 'spring|spring-headless|spring-dedicated' 2>/dev/null | awk 'NF')"
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
  python_bar_launch_survivors="$(pgrep -f 'python.* -m bar_launch' 2>/dev/null | awk 'NF')"
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
