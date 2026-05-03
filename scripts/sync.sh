#!/usr/bin/env bash
# scripts/sync.sh -- WSL-side orchestration for the Phase 3 sync daemon.
#
# Starts a Windows-side `python -m sync.py` in the background that mirrors
# three WSL Devtools subtrees (Beyond-All-Reason, BYAR-Chobby, RecoilEngine
# build output) into the Windows-NTFS sync target ($BAR_DEVSYNC_DIR).
#
# Usage:
#   scripts/sync.sh start          # cold copy + start watcher; PID -> state file
#   scripts/sync.sh stop           # send SIGTERM to the running watcher
#   scripts/sync.sh status         # is the watcher up? print PID + log path
#   scripts/sync.sh once           # do a one-shot cold copy and exit
#   scripts/sync.sh logs [-f]      # tail the sync log
#
# scripts/launch.sh's run_wsl branch invokes `start` before exec'ing the
# Windows shim and `stop` on exit so a dev session has bounded resource use.
#
# Expects (set by Justfile dotenv-load or the caller):
#   DEVTOOLS_DIR        path to the BAR-Devtools checkout
#   BAR_DEVSYNC_DIR     WSL form of the Windows-side sync target
#   WSL_DISTRO_NAME     (auto, exported by WSL itself)

set -euo pipefail

: "${DEVTOOLS_DIR:?DEVTOOLS_DIR must be set (Justfile exports it)}"
source "$DEVTOOLS_DIR/scripts/common.sh"

if [ -z "${BAR_DEVSYNC_DIR:-}" ]; then
  err "BAR_DEVSYNC_DIR not set. Run 'just setup::init' on WSL2 first."
  exit 1
fi

if ! grep -qi microsoft /proc/version 2>/dev/null; then
  err "scripts/sync.sh only runs on WSL2 (the watcher is a Windows process)."
  exit 1
fi

if [ -z "${WSL_DISTRO_NAME:-}" ]; then
  err "WSL_DISTRO_NAME not set -- can't compute UNC source paths."
  err "Open a shell from Windows Terminal's WSL profile (it sets this) or"
  err "export WSL_DISTRO_NAME manually."
  exit 1
fi

# State files under <BAR_DEVSYNC_DIR>/.bar-launch/. Stays inside the sync
# dir so a sync-dir reset wipes residual state too. Linux side reads the
# .pid via cat; the Windows side never touches it.
STATE_DIR="$BAR_DEVSYNC_DIR/.bar-launch"
PID_FILE="$STATE_DIR/sync.pid"
LOG_FILE="$STATE_DIR/sync.log"
READY_FILE="$STATE_DIR/sync.ready"

mkdir -p "$STATE_DIR"

# UNC source paths (Windows form). The Devtools repo dirs live on WSL ext4;
# the watcher reads them via Plan9. We compute these once and pass into
# sync.py via --pair so the daemon doesn't have to grok wslpath itself.
#
# Two non-obvious points:
#   1. We resolve symlinks (readlink -f) BEFORE constructing the UNC path.
#      The Devtools workspace symlinks (e.g. Beyond-All-Reason -> ~/code/...)
#      are created by the @local_root pattern in repos.local.conf. Windows
#      reading through Plan9 does not transparently follow these -- the
#      daemon's Path.exists() returns False on the symlink itself and we
#      end up with "0 handler(s) scheduled" + an empty mirror.
#   2. We use the modern \\wsl.localhost\<distro>\... form (via wslpath -w)
#      rather than the legacy \\wsl$\<distro>\..., because on Win11 24H2+
#      the legacy alias's behavior with reparse points is unreliable.
_unc_for() {
  local wsl_path="$1"
  local resolved
  resolved="$(readlink -f "$wsl_path" 2>/dev/null || echo "$wsl_path")"
  if command -v wslpath &>/dev/null; then
    wslpath -w "$resolved"
  else
    # Fallback if wslpath is unavailable (shouldn't happen on real WSL2):
    # construct the modern UNC form by hand.
    local rel="${resolved#/}"
    echo "\\\\wsl.localhost\\${WSL_DISTRO_NAME}\\${rel//\//\\}"
  fi
}

_win_for() {
  local wsl_path="$1"
  if command -v wslpath &>/dev/null; then
    wslpath -w "$wsl_path"
  else
    echo "$wsl_path"
  fi
}

# The three sync pairs. Sources are the Devtools-checked-out repos; targets
# are the data-dir subpaths the engine reads from.
#
# RecoilEngine source is the docker-build-v2 install dir, not the repo root --
# the engine binary + bundled dlls live in build-amd64-windows/install. If
# someone hasn't built the engine yet the source won't exist; sync.py warns
# and skips that pair.
_compute_pairs() {
  local pairs=()
  local engine_src="$DEVTOOLS_DIR/RecoilEngine/build-amd64-windows/install"
  local bar_src="$DEVTOOLS_DIR/Beyond-All-Reason"
  local chobby_src="$DEVTOOLS_DIR/BYAR-Chobby"

  local engine_dst="$BAR_DEVSYNC_DIR/engine/local-build"
  # Spring's archive scanner registers unpacked-directory archives only when
  # the dir has a .sdd suffix (sd7/sdz are the compressed forms; sdd is the
  # "spring data directory" marker). Without it, scan() walks the dir but
  # never adds it to the archive cache and --menu / --game lookups fail with
  # "Dependent archive '...' not found". Verified empirically on Win11/WSL2.
  local bar_dst="$BAR_DEVSYNC_DIR/games/Beyond-All-Reason.sdd"
  local chobby_dst="$BAR_DEVSYNC_DIR/games/BYAR-Chobby.sdd"

  if [ -d "$engine_src" ]; then
    pairs+=("$(_unc_for "$engine_src")::$(_win_for "$engine_dst")")
  fi
  if [ -d "$bar_src" ]; then
    pairs+=("$(_unc_for "$bar_src")::$(_win_for "$bar_dst")")
  fi
  if [ -d "$chobby_src" ]; then
    pairs+=("$(_unc_for "$chobby_src")::$(_win_for "$chobby_dst")")
  fi

  if [ "${#pairs[@]}" -eq 0 ]; then
    err "No sync sources found. Clone Beyond-All-Reason / BYAR-Chobby and run 'just engine::build windows'."
    return 1
  fi

  printf '%s\n' "${pairs[@]}"
}

_resolve_venv_python() {
  local venv_python="$BAR_DEVSYNC_DIR/.venv/Scripts/python.exe"
  if [ ! -f "$venv_python" ]; then
    err "Windows venv python not found at $venv_python"
    err "Run 'just setup::init' on WSL2 to bootstrap it."
    return 1
  fi
  _win_for "$venv_python"
}

# Is the recorded PID still alive on the Windows side? We don't kill across
# the WSL boundary; we ask Windows. tasklist returns 1 when no process
# matches, 0 when one does (regardless of header noise).
_pid_alive() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  command -v tasklist.exe &>/dev/null || return 1
  tasklist.exe /FI "PID eq $pid" /NH 2>/dev/null | grep -qE "^\s*python\.exe" \
    || tasklist.exe /FI "PID eq $pid" /NH 2>/dev/null | grep -qE "^\s*py\.exe"
}

cmd_status() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE")"
    if _pid_alive "$pid"; then
      ok "sync watcher running (Windows PID $pid)"
      info "log: $LOG_FILE"
      return 0
    else
      warn "stale pid file ($pid not alive on Windows side)"
      rm -f "$PID_FILE" "$READY_FILE"
    fi
  fi
  info "sync watcher not running"
  return 1
}

cmd_once() {
  local venv_py
  venv_py="$(_resolve_venv_python)" || exit 1
  local sync_py_win
  sync_py_win="$(_win_for "$DEVTOOLS_DIR/scripts/sync.py")"

  local pair_args=()
  local p
  while IFS= read -r p; do pair_args+=(--pair "$p"); done < <(_compute_pairs)

  step "Cold copy (one-shot)"
  cmd.exe /c "\"$venv_py\" \"$sync_py_win\" --cold-copy --log \"$(_win_for "$LOG_FILE")\" ${pair_args[*]}"
  ok "cold copy complete"
}

cmd_start() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE")"
    if _pid_alive "$pid"; then
      info "sync watcher already running (Windows PID $pid)"
      return 0
    fi
    rm -f "$PID_FILE"
  fi

  local venv_py
  venv_py="$(_resolve_venv_python)" || exit 1
  local sync_py_win
  sync_py_win="$(_win_for "$DEVTOOLS_DIR/scripts/sync.py")"
  local log_win ready_win
  log_win="$(_win_for "$LOG_FILE")"
  ready_win="$(_win_for "$READY_FILE")"

  rm -f "$READY_FILE"

  local pair_args=()
  local p
  while IFS= read -r p; do pair_args+=(--pair "$p"); done < <(_compute_pairs) \
    || exit 1

  # Spawn the watcher as a detached Windows process via PowerShell's
  # Start-Process -PassThru. We tried wmic first; cmd.exe's quoting rules
  # don't honor backslash-escapes inside "..." so the executable path
  # arrived at wmic mangled and CreateProcess returned 9 (Path Not Found).
  # PowerShell's single-quoted string literals have no backslash escapes,
  # so UNC paths (`\\wsl.localhost\...`) and `C:\...` paths round-trip
  # cleanly. We feed the script via -EncodedCommand (UTF-16LE base64) to
  # bypass cmd.exe entirely; PowerShell.exe parses argv directly.
  step "Starting sync watcher"

  # Single-quote a string for embedding in a PowerShell '...' literal.
  # Inside '...' the only escape is '' -> a single literal quote.
  _ps_quote() { printf "'%s'" "${1//\'/\'\'}"; }

  local ps_arglist=""
  ps_arglist+="$(_ps_quote "$sync_py_win")"
  ps_arglist+=",$(_ps_quote "--log"),$(_ps_quote "$log_win")"
  ps_arglist+=",$(_ps_quote "--ready-file"),$(_ps_quote "$ready_win")"
  local i
  for ((i = 0; i < ${#pair_args[@]}; i += 2)); do
    ps_arglist+=",$(_ps_quote "${pair_args[i]}"),$(_ps_quote "${pair_args[i+1]}")"
  done

  # $p.Id on its own line is the only stdout we expect on success; any
  # PowerShell warning (e.g. UNC-cwd) or error gets caught in stderr and
  # surfaces in the diagnostic block below.
  local ps_script
  ps_script="\$ErrorActionPreference = 'Stop'
\$p = Start-Process -FilePath $(_ps_quote "$venv_py") -ArgumentList @($ps_arglist) -PassThru -WindowStyle Hidden
Write-Output \$p.Id"

  local encoded
  encoded="$(printf '%s' "$ps_script" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"

  local create_output=""
  create_output="$(powershell.exe -NoProfile -NonInteractive -EncodedCommand "$encoded" 2>&1)" || true

  # PID is the only digits-only line on stdout; CR-strip + grep guards
  # against a stray "UNC paths are not supported" notice from PowerShell.
  local pid=""
  pid="$(echo "$create_output" | tr -d '\r' | grep -E '^[0-9]+$' | tail -n1)" || true
  if [ -z "$pid" ]; then
    err "Failed to start sync watcher; PowerShell output:"
    echo "$create_output" >&2
    return 1
  fi
  echo "$pid" > "$PID_FILE"
  ok "sync watcher started (Windows PID $pid)"

  # Wait up to ~10s for the ready flag (cold copy + watcher init).
  local waited=0
  while [ ! -f "$READY_FILE" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if [ -f "$READY_FILE" ]; then
    ok "sync watcher ready (initial mirror quiesced in $((waited * 100))ms)"
  else
    warn "sync watcher didn't signal ready within 10s -- continuing anyway"
    warn "Check the log: $LOG_FILE"
  fi
}

cmd_stop() {
  if [ ! -f "$PID_FILE" ]; then
    info "no PID file at $PID_FILE -- nothing to stop"
    return 0
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  if [ -z "$pid" ]; then
    rm -f "$PID_FILE" "$READY_FILE"
    return 0
  fi
  if _pid_alive "$pid"; then
    info "stopping sync watcher (Windows PID $pid)"
    # /T kills the tree; the watcher launches no children but it's defensive.
    taskkill.exe /PID "$pid" /T /F >/dev/null 2>&1 || true
  fi
  rm -f "$PID_FILE" "$READY_FILE"
  ok "sync watcher stopped"
}

cmd_logs() {
  if [ ! -f "$LOG_FILE" ]; then
    info "no log yet at $LOG_FILE -- has the watcher run?"
    return 0
  fi
  exec tail "$@" "$LOG_FILE"
}

case "${1:-status}" in
  start)  shift; cmd_start "$@" ;;
  stop)   shift; cmd_stop  "$@" ;;
  status) shift; cmd_status "$@" ;;
  once)   shift; cmd_once  "$@" ;;
  logs)   shift; cmd_logs "$@"  ;;
  *)
    err "Unknown subcommand: $1"
    echo "Usage: scripts/sync.sh {start|stop|status|once|logs}" >&2
    exit 2
    ;;
esac
