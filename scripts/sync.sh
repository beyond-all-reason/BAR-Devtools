#!/usr/bin/env bash
# WSL-side mirror daemon: watches WSL Devtools subtrees (Beyond-All-Reason,
# BYAR-Chobby, RecoilEngine install/) on native inotify and writes through
# /mnt/c into $BAR_DATA_DIR -- the spring data dir.
#
# Subcommands:
#   start [--wait-ready]   start daemon (cold-copies, then watches; idempotent)
#   stop                   SIGTERM, wait, SIGKILL
#   status                 PID + alive/dead
#   cold-copy              one-shot seed of source pairs (no watcher); used by
#                          setup::init to pre-warm Watchman state in AFK time
#   mirror-engine          one-shot cold copy of the engine pair
#   logs [-f|...]          tail the daemon log

set -euo pipefail

: "${DEVTOOLS_DIR:?DEVTOOLS_DIR must be set (Justfile exports it)}"
source "$DEVTOOLS_DIR/scripts/common.sh"

# This entry-point script (start/stop/status/etc.) runs on the WSL host.
# It enters the bar-sync container to run the actual python daemon -- see
# docker/sync.Containerfile for what's in there. Must not run from inside
# bar-dev (Windows interop + container-from-container is fragile).
require_host

if [ -z "${BAR_DATA_DIR:-}" ]; then
  err "BAR_DATA_DIR not set. Run 'just setup::init' on WSL2 first."
  exit 1
fi

if ! grep -qi microsoft /proc/version 2>/dev/null; then
  err "scripts/sync.sh only runs on WSL2 (target is a Windows-side data dir)."
  exit 1
fi

# Confirm the sync container exists before any subcommand tries to enter it.
# Cheaper than letting `distrobox enter` fail with a confusing message inside
# a backgrounded nohup pipeline.
#
# Don't use `grep -q`: under `set -o pipefail` (set at the top of this file),
# grep -q exits at the first match and SIGPIPEs `distrobox list` on the next
# write, leaving the pipeline rc=141 and the negation flipping a successful
# match into a failure. Capturing the listing into a variable first sidesteps
# the pipe race entirely.
_require_sync_distrobox() {
  local listing
  listing="$(distrobox list 2>/dev/null || true)"
  if ! printf '%s\n' "$listing" | grep -F "| ${DEVTOOLS_SYNC_DISTROBOX} " >/dev/null 2>&1; then
    err "sync container '${DEVTOOLS_SYNC_DISTROBOX}' does not exist."
    info "Build it: just setup::distrobox  (creates bar-dev + bar-sync on WSL)"
    return 1
  fi
}

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

  _require_sync_distrobox || return 1

  # Engine pair is mirrored on demand from cmd_mirror_engine; never watched
  # (it would race the build hook).
  local pair_args=()
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && pair_args+=(--pair "$p")
  done <<<"$pair_lines"

  rm -f "$READY_FILE"

  step "Starting sync daemon (cold-copy + watcher) inside ${DEVTOOLS_SYNC_DISTROBOX}"
  info "log: $LOG_FILE  (live: just bar::sync-logs)"
  : >"$LOG_FILE"
  # The PID we save is the host-side `distrobox enter` shim; it forwards
  # SIGTERM to the in-container python3 on stop. Container stays alive as
  # long as that process is alive (distrobox/podman semantics).
  nohup distrobox enter "${DEVTOOLS_SYNC_DISTROBOX}" -- \
      python3 "$DEVTOOLS_DIR/scripts/sync.py" \
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

# One-shot cold-copy of the source pairs (no watcher). Pre-warms the
# Watchman clock + per-pair state file so the next `cmd_start` skips the
# rsync stat-walk and goes straight to the incremental-delta path.
# Without this, a fresh BAR + chobby seed on slow drvfs has been observed
# to exceed _wait_for_ready's 300s bound on the first `bar::launch`.
# Engine pair stays excluded -- mirrored separately by cmd_mirror_engine.
cmd_cold_copy() {
  local pair_lines
  if ! pair_lines="$(_compute_source_pairs)"; then
    return 1
  fi

  _require_sync_distrobox || return 1

  local pair_args=()
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && pair_args+=(--pair "$p")
  done <<<"$pair_lines"

  step "Cold-copy seed (one-shot, no watcher) inside ${DEVTOOLS_SYNC_DISTROBOX}"
  info "log: $LOG_FILE  (live: just bar::sync-logs)"
  : >"$LOG_FILE"

  # Stream log to stderr so the user sees rsync/watchman progress instead
  # of a frozen screen during the seed; mirrors _wait_for_ready's pattern.
  tail -F -n 0 "$LOG_FILE" >&2 &
  local tail_pid=$!
  disown "$tail_pid" 2>/dev/null || true

  local rc=0
  distrobox enter "${DEVTOOLS_SYNC_DISTROBOX}" -- \
      python3 "$DEVTOOLS_DIR/scripts/sync.py" \
      --log "$LOG_FILE" \
      --cold-copy \
      "${pair_args[@]}" \
      </dev/null >>"$LOG_FILE" 2>&1 || rc=$?

  kill "$tail_pid" 2>/dev/null || true
  if [ $rc -eq 0 ]; then
    ok "Cold-copy seed complete -- next bar::launch will be incremental."
  else
    err "Cold-copy seed failed (rc=$rc). See $LOG_FILE."
    err "First 'just bar::launch' will fall back to a full rsync seed."
  fi
  return $rc
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

  _require_sync_distrobox || return 1
  step "Mirroring engine artifacts to $BAR_DATA_DIR/engine/local-build (via ${DEVTOOLS_SYNC_DISTROBOX})"
  distrobox enter "${DEVTOOLS_SYNC_DISTROBOX}" -- \
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
  cold-copy)     shift; cmd_cold_copy "$@" ;;
  mirror-engine) shift; cmd_mirror_engine "$@" ;;
  logs)          shift; cmd_logs "$@" ;;
  *)
    err "Unknown subcommand: $1"
    echo "Usage: scripts/sync.sh {start [--wait-ready]|stop|status|cold-copy|mirror-engine|logs}" >&2
    exit 2
    ;;
esac
