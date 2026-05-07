#!/usr/bin/env bash
# WSL-side mirror daemon: watches WSL Devtools subtrees (Beyond-All-Reason,
# BYAR-Chobby, RecoilEngine install/) on native inotify and writes through
# /mnt/c into $BAR_DATA_DIR -- the spring data dir.
#
# Subcommands:
#   start [--wait-ready]   start daemon (cold-copies, then watches; idempotent)
#   stop                   SIGTERM, wait, SIGKILL
#   status                 PID + alive/dead
#   mirror-engine          one-shot cold copy of the engine pair
#   logs [-f|...]          tail the daemon log

set -euo pipefail

: "${DEVTOOLS_DIR:?DEVTOOLS_DIR must be set (Justfile exports it)}"
source "$DEVTOOLS_DIR/scripts/common.sh"

# Watchman, /mnt/c writes, and Windows interop (tasklist.exe etc.) all need
# the WSL host -- not the bar-dev distrobox where watchman's per-user state
# dir is unreadable.
require_host

if [ -z "${BAR_DATA_DIR:-}" ]; then
  err "BAR_DATA_DIR not set. Run 'just setup::init' on WSL2 first."
  exit 1
fi

if ! grep -qi microsoft /proc/version 2>/dev/null; then
  err "scripts/sync.sh only runs on WSL2 (target is a Windows-side data dir)."
  exit 1
fi

STATE_DIR="$BAR_DATA_DIR/.bar-launch"
LOG_FILE="$STATE_DIR/sync.log"
PID_FILE="$STATE_DIR/sync.pid"
READY_FILE="$STATE_DIR/sync.ready"
mkdir -p "$STATE_DIR"

# `.sdd` suffix on the destinations is required: spring's archive scanner
# only registers unpacked-dir archives when the dir name ends in .sdd.
_compute_source_pairs() {
  local pairs=()
  local missing=()
  local bar_src="$DEVTOOLS_DIR/Beyond-All-Reason"
  local chobby_src="$DEVTOOLS_DIR/BYAR-Chobby"
  local bar_dst="$BAR_DATA_DIR/games/Beyond-All-Reason.sdd"
  local chobby_dst="$BAR_DATA_DIR/games/BYAR-Chobby.sdd"

  # Distinguish "never linked" (silent skip) from "linked but target
  # vanished" (must shout: edits would go to a path the daemon doesn't watch).
  _classify_pair() {
    local name="$1" src="$2" dst="$3"
    if [ -L "$src" ] && [ ! -e "$src" ]; then
      missing+=("$name (broken symlink: $src -> $(readlink "$src"))")
    elif [ -d "$src" ]; then
      pairs+=("$(readlink -f "$src")::$dst")
    fi
  }
  _classify_pair "Beyond-All-Reason" "$bar_src"    "$bar_dst"
  _classify_pair "BYAR-Chobby"       "$chobby_src" "$chobby_dst"
  unset -f _classify_pair

  if [ "${#missing[@]}" -gt 0 ]; then
    err "sync source(s) configured but not resolvable:"
    local m
    for m in "${missing[@]}"; do err "  - $m"; done
    err "Recreate the link(s):"
    err "  just link::create bar       # for Beyond-All-Reason"
    err "  just link::create chobby    # for BYAR-Chobby"
    err "Or re-run 'just setup::init' to refresh repos.local.conf."
    return 1
  fi

  if [ "${#pairs[@]}" -eq 0 ]; then
    err "No sync sources found. Clone Beyond-All-Reason / BYAR-Chobby"
    err "(just repos::clone bar / chobby) and link them with"
    err "(just link::create bar / chobby)."
    return 1
  fi

  printf '%s\n' "${pairs[@]}"
}

# Engine pair stays out of the watcher: engine artifacts change at build
# pace, not edit pace. Mirrored on demand from `just engine::build`'s hook.
_compute_engine_pair() {
  local engine_src="$DEVTOOLS_DIR/RecoilEngine/build-amd64-windows/install"
  local engine_dst="$BAR_DATA_DIR/engine/local-build"
  if [ ! -d "$engine_src" ]; then
    return 1
  fi
  echo "$(readlink -f "$engine_src")::$engine_dst"
}

_pid_alive() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

_running_pid() {
  [ -f "$PID_FILE" ] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if _pid_alive "$pid"; then
    echo "$pid"
    return 0
  fi
  return 1
}

cmd_status() {
  local pid
  if pid="$(_running_pid)"; then
    info "sync daemon running, PID $pid (log: $LOG_FILE)"
    return 0
  fi
  info "sync daemon not running"
  return 1
}

cmd_start() {
  local wait_ready=0
  if [ "${1:-}" = "--wait-ready" ]; then
    wait_ready=1
    shift
  fi

  # Validate pairs BEFORE the already-running check: a stale daemon would
  # otherwise mask broken-symlink errors and silently not sync the user's edits.
  local pair_lines
  if ! pair_lines="$(_compute_source_pairs)"; then
    return 1
  fi

  local existing_pid
  if existing_pid="$(_running_pid)"; then
    # Detect pair-list drift: if a running daemon was started with different
    # --pair args than the current config produces, restart so it picks up
    # the new pairs instead of silently watching stale paths.
    local cmdline live_pairs expected_pairs
    cmdline="$(tr '\0' ' ' < /proc/"$existing_pid"/cmdline 2>/dev/null)"
    live_pairs="$(echo "$cmdline" | awk 'BEGIN{RS=" "} /::/{print}' | sort -u)"
    expected_pairs="$(echo "$pair_lines" | sort -u)"

    if [ "$live_pairs" != "$expected_pairs" ]; then
      warn "sync daemon (PID $existing_pid) was started with a different set of pairs than the current config:"
      warn "  live pairs:"
      while IFS= read -r line; do [ -n "$line" ] && warn "    $line"; done <<<"$live_pairs"
      warn "  expected pairs (per current symlinks / repos.conf):"
      while IFS= read -r line; do [ -n "$line" ] && warn "    $line"; done <<<"$expected_pairs"
      err "Edits to paths in the expected list will NOT propagate -- the running daemon doesn't watch them."
      err "Restart to pick up the new config:"
      err "  bash $DEVTOOLS_DIR/scripts/sync.sh stop"
      err "  bash $DEVTOOLS_DIR/scripts/sync.sh start --wait-ready"
      return 1
    fi

    if [ -f "$READY_FILE" ]; then
      info "sync daemon already running and ready (PID $existing_pid)"
    else
      warn "sync daemon running (PID $existing_pid) but ready-flag missing"
      info "  (likely an orphan from a prior version; continuing without re-verify)"
      info "  to refresh: bash $DEVTOOLS_DIR/scripts/sync.sh stop && ... start --wait-ready"
    fi
    return 0
  fi

  if ! command -v python3 &>/dev/null; then
    err "python3 not found on PATH. Install via your distro's package manager."
    return 1
  fi
  if ! python3 -c 'import watchdog' &>/dev/null; then
    err "python3 watchdog module not available."
    info "On Ubuntu/WSL2: sudo apt-get install -y python3-watchdog"
    info "Or re-run: just setup::init"
    return 1
  fi

  # Engine pair is mirrored on demand from cmd_mirror_engine; never watched
  # (it would race the build hook).
  local pair_args=()
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && pair_args+=(--pair "$p")
  done <<<"$pair_lines"

  rm -f "$READY_FILE"

  step "Starting sync daemon (cold-copy + watcher)"
  info "log: $LOG_FILE  (live: just bar::sync-logs -- -F)"
  : >"$LOG_FILE"
  nohup python3 "$DEVTOOLS_DIR/scripts/sync.py" \
      --log "$LOG_FILE" \
      --ready-file "$READY_FILE" \
      "${pair_args[@]}" \
      </dev/null >>"$LOG_FILE" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  echo "$pid" > "$PID_FILE"
  ok "sync daemon started, PID $pid"

  if [ "$wait_ready" = "1" ]; then
    _wait_for_ready "$pid"
  fi
}

# Wait up to 300s for sync.py to touch READY_FILE (after cold-copy + watcher
# scheduling). Cold-copy time scales with the size of the source trees; for
# the full BAR + chobby + engine set on a slow disk this can sit in the
# 60-180s range, so 300s is the conservative bound. While we wait we tail
# the daemon log to stderr so the user sees cold-copy progress instead of
# a screen that looks frozen. If the daemon dies before signalling ready,
# surface that immediately.
_wait_for_ready() {
  local pid="${1:-}"
  if [ -z "$pid" ]; then pid="$(cat "$PID_FILE" 2>/dev/null || true)"; fi

  info "waiting for cold copy to finish (this can be 30-180s on first run)..."
  # tail -F (capital) follows recreates/truncates that cmd_start did just before us.
  tail -F -n 0 "$LOG_FILE" >&2 &
  local tail_pid=$!
  disown "$tail_pid" 2>/dev/null || true

  local deadline=$((SECONDS + 300))
  local rc=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -f "$READY_FILE" ]; then
      kill "$tail_pid" 2>/dev/null || true
      ok "sync daemon ready (cold-copy + watcher up)"
      return 0
    fi
    if [ -n "$pid" ] && ! _pid_alive "$pid"; then
      kill "$tail_pid" 2>/dev/null || true
      err "sync daemon exited before signalling ready (see $LOG_FILE)"
      return 1
    fi
    sleep 0.25
  done
  kill "$tail_pid" 2>/dev/null || true
  err "sync daemon did not signal ready within 300s (see $LOG_FILE)"
  return 1
}

cmd_stop() {
  local pid
  if ! pid="$(_running_pid)"; then
    info "sync daemon not running"
    rm -f "$PID_FILE"
    return 0
  fi
  step "Stopping sync daemon (PID $pid)"
  kill -TERM "$pid" 2>/dev/null || true
  # Up to 5s for sync.py's signal handler to drain pending events.
  local i=0
  while [ $i -lt 50 ]; do
    if ! _pid_alive "$pid"; then
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if _pid_alive "$pid"; then
    warn "sync daemon did not exit on SIGTERM; sending SIGKILL"
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE" "$READY_FILE"
  ok "sync daemon stopped"
}

cmd_mirror_engine() {
  local engine_pair
  if ! engine_pair="$(_compute_engine_pair)"; then
    warn "no engine build at $DEVTOOLS_DIR/RecoilEngine/build-amd64-windows/install -- skipping mirror"
    return 0
  fi

  # Defensive preflight: engine.just runs the same check earlier, but
  # `sync.sh mirror-engine` is also reachable directly. A live spring.exe
  # share-locks the engine DLLs; rsync through drvfs would EACCES per file
  # and leave a half-mirrored install.
  local holders
  if ! holders="$(_engine_holders)"; then
    err "Cannot mirror engine -- the following process(es) are running and hold the engine binaries:"
    while IFS= read -r h; do err "  - $h"; done <<<"$holders"
    err "Stop them first, then re-run 'just engine::build windows' (or just 'sync.sh mirror-engine'):"
    err "  just bar::stop"
    return 1
  fi

  step "Mirroring engine artifacts to $BAR_DATA_DIR/engine/local-build"
  python3 "$DEVTOOLS_DIR/scripts/sync.py" --cold-copy --log "$LOG_FILE" --pair "$engine_pair"
  ok "engine mirrored"
}

cmd_logs() {
  if [ ! -f "$LOG_FILE" ]; then
    info "no log yet at $LOG_FILE"
    return 0
  fi
  exec tail "$@" "$LOG_FILE"
}

case "${1:-status}" in
  start)         shift; cmd_start "$@" ;;
  stop)          shift; cmd_stop  "$@" ;;
  status)        shift; cmd_status "$@" ;;
  mirror-engine) shift; cmd_mirror_engine "$@" ;;
  logs)          shift; cmd_logs "$@" ;;
  *)
    err "Unknown subcommand: $1"
    echo "Usage: scripts/sync.sh {start [--wait-ready]|stop|status|mirror-engine|logs}" >&2
    exit 2
    ;;
esac
