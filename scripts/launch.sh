#!/usr/bin/env bash
# `just bar::launch` entry point. Linux: exec bar-launch directly. WSL2:
# bring up the sync daemon, then invoke the Windows-side bar-launch.cmd
# shim so spring.exe runs as a native Windows process.

set -euo pipefail

# repos.sh expects REPOS_CONF / REPOS_LOCAL to be exported by the calling
# Justfile module. The launch recipe lives in bar.just where they aren't set,
# so default them here -- matching the values just/repos.just exports.
: "${REPOS_CONF:=$DEVTOOLS_DIR/repos.conf}"
: "${REPOS_LOCAL:=$DEVTOOLS_DIR/repos.local.conf}"
export REPOS_CONF REPOS_LOCAL

source "$DEVTOOLS_DIR/scripts/common.sh"
source "$DEVTOOLS_DIR/scripts/setup.sh"
source "$DEVTOOLS_DIR/scripts/repos.sh"

# Refuse to run from inside bar-dev: watchman/Windows-interop need the host.
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

# NOTE: chobby-channel selection lives in setup::init's module registry
# now (scripts/setup/30-chobby-channel.sh). bar::launch trusts that the
# user made the choice at setup time; if they want to revisit it, that's
# `just bar::dev-mode` (which calls apply_chobby_channel directly).

run_linux() {
  if ! command -v bar-launch &>/dev/null; then
    err "bar-launch not on PATH"
    info "Run 'just setup::init' (pipx-installs the launcher), or run 'pipx ensurepath' if it's already installed."
    exit 1
  fi
  local repo_path
  repo_path="$(bar_launch_repo_path)"

  # Manifest-staleness check: if pyproject.toml has been touched since the
  # install marker, bar_debug_launcher's pip deps may have changed. Editable
  # installs auto-pick-up .py edits but pinning a new dep needs a reinstall.
  # Keeping this in the launch path (not setup) so contributors who pull
  # don't have to remember to re-run setup before the launcher breaks on a
  # fresh import.
  local marker="${XDG_STATE_HOME:-$HOME/.local/state}/bar-devtools/bar-launch-installed"
  local pyproject="$repo_path/pyproject.toml"
  if [ -f "$pyproject" ] && [ -f "$marker" ] && [ "$pyproject" -nt "$marker" ]; then
    info "$(basename "$repo_path")/pyproject.toml is newer than the bar-launch install -- reinstalling"
    ensure_bar_launch_installed "$repo_path" || exit 1
  fi

  preflight_symlinks

  # Auto-inject flags from what's locally checked out, so a contributor who
  # ran `just link::create engine` doesn't also have to remember to type
  # `--engine local-build`. We only inject flags the user didn't already
  # supply -- explicit user args always win.
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

  # The launcher's autodetect anchors itself on $0's directory; we want it
  # anchored on the Devtools-managed checkout, not on this script.
  cd "$repo_path"

  info "Running: bar-launch ${injected[*]:-} ${user_args[*]:-}"
  exec bar-launch "${injected[@]}" "${user_args[@]}"
}

# True if $1 (a flag like --engine) appears anywhere in the remaining args.
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

# Pop a known boolean flag from "$@" by name. Echoes the remaining args (one
# per NUL byte). Bash arrays don't survive function returns, so the caller
# does:  mapfile -d '' filtered < <(_strip_flag --debug-gl "$@")
_strip_flag() {
  local needle="$1"; shift
  local arg
  for arg in "$@"; do
    if [ "$arg" = "$needle" ]; then continue; fi
    printf '%s\0' "$arg"
  done
}

# Whitelist of springsettings.cfg keys this launcher manages on behalf of
# its own --flag opts. One row per (flag, key) pair:
#   <bar-launch-flag>  <SpringSettingsKey>  <on_value>  <off_value>
#
# This is the *only* place we touch springsettings.cfg programmatically;
# every launch resets every key in this table to either its on_value
# (flag present in args) or its off_value (flag absent), so a prior
# launch's settings cannot leak into the current one. Adding a new
# debug-knob flag = adding rows here, nothing else.
#
# The cfg is otherwise managed by the engine and the user; keys we don't
# list here are never read or written by us.
_MANAGED_SPRINGSETTINGS=(
  "--debug-gl  DebugGL   1  0"
  "--debug-gl  LogFlush  1  0"
)

# Reset every managed key to the value matching the current arg set. Each
# row in _MANAGED_SPRINGSETTINGS is applied independently; flags can share
# keys (last-write wins per row order) but in practice each key has one
# owning flag.
#
# Gated on ALLOW_SPRINGSETTINGS_MOD (1/true/yes). Default off: we will
# never touch the user's springsettings.cfg unless they explicitly opted
# in during `just setup::init`. If a managed flag was passed without the
# opt-in, we surface a single-line warning per flag so the user knows the
# flag was ignored and how to enable it -- but we do not silently apply.
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
          # Each flag may own multiple keys; warn once per flag.
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
    # Surface a warning per flag the user did request, since we couldn't
    # honor it. Keys without a requesting flag stay silent.
    local entry flag _rest
    for entry in "${_MANAGED_SPRINGSETTINGS[@]}"; do
      read -r flag _rest <<<"$entry"
      if _has_flag "$flag" "$@"; then
        warn "$flag requested but no springsettings.cfg path resolved; skipping"
      fi
    done
    return 0
  fi

  # Log once per flag that's actually on (not once per key it owns).
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
      # Silent reset to off_value so a prior on-launch doesn't carry over.
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

  # Strip --debug-gl from forwarded args so the Windows-side launcher /
  # spring.exe doesn't try to interpret it.
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

  # --wait-ready blocks until cold copy + watcher are up so spring.exe
  # doesn't see a half-mirrored data dir.
  bash "$DEVTOOLS_DIR/scripts/sync.sh" start --wait-ready \
    || { err "sync daemon failed to start (see logs: just bar::sync-logs)"; exit 1; }

  local shim_win
  shim_win="$(wslpath -w "$shim_wsl")"

  # printf, not info: `echo -e` interprets \b in ...\bin\... as backspace.
  printf '\033[0;34m[info]\033[0m  Launching detached: %s %s\n' "$shim_win" "${launch_args[*]}"
  printf '\033[0;34m[info]\033[0m  logs:  just bar::log -- -F      (engine infolog)\n'
  printf '\033[0;34m[info]\033[0m         just bar::sync-logs -- -F (cold-copy log)\n'

  # Detach via nohup + & + disown so the Electron launcher's ~10-30s
  # graceful shutdown doesn't block our return.
  # Plain `cmd.exe /c <shim> <args>` -- NOT `start "" /B "<shim>"`. The
  # embedded "" quotes get double-escaped by WSL2 interop's argv encoder
  # and cmd.exe tries to execute a literal `\` as a command.
  # cd /mnt/c gives cmd.exe a drive-letter cwd (avoids UNC warning).
  ( cd /mnt/c && nohup cmd.exe /c "$shim_win" "${launch_args[@]}" </dev/null >/dev/null 2>&1 & )
  return 0
}

# Kill what bar::launch spawned: spring.exe, Beyond-All-Reason.exe (Electron
# launcher; only if the user double-clicked it -- but it locks the same
# engine DLLs, so we include it), and the bar_launch python.exe (filtered
# by command line so we don't touch unrelated Pythons).
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

  # Identify our python.exe by command line (CIM, since wmic is gone in
  # 24H2+). Kill via taskkill not Stop-Process -- the latter has silently
  # under-killed in past, taskkill matches what worked for spring.exe above.
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

  # Symmetric tear-down: launch brought the daemon up; stop brings it down.
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

  # bar_debug_launcher: matches `python -m bar_launch ...`. -f matches
  # against the full cmdline so we don't mistake other Pythons for ours.
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

  # Engine: scope the kill to spring binaries running out of *our* game
  # dir. The previous version refused to touch spring at all because a
  # naive `pkill spring` on a shared dev box would hit unrelated engines.
  # Filtering by /proc/<pid>/exe path makes this safe.
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

  # Verify TERM took. Anything still alive after a brief grace period
  # gets SIGKILL -- mirrors the `taskkill /F` semantics on the WSL side.
  sleep 0.3
  local survivors
  survivors="$(pgrep -f 'python.* -m bar_launch' 2>/dev/null | awk 'NF')"
  if [ -n "$survivors" ]; then
    while IFS= read -r pid; do
      [ -z "$pid" ] && continue
      if kill -KILL "$pid" 2>/dev/null; then
        warn "  SIGKILL'd surviving python -m bar_launch (PID $pid)"
      else
        warn "  PID $pid (bar_launch) survived SIGTERM and SIGKILL failed"
      fi
    done <<<"$survivors"
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
