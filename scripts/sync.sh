#!/usr/bin/env bash
# scripts/sync.sh -- WSL-side native-inotify mirror for the dev data dir.
#
# Mirrors WSL Devtools subtrees (Beyond-All-Reason, BYAR-Chobby, the
# RecoilEngine build output) into the Windows-NTFS sync target
# ($BAR_DEVSYNC_DIR) the engine reads from. The watcher runs on the WSL
# side (native inotify on ext4) and writes through /mnt/c, so source
# edits propagate at ~100 ms median to the engine's read path. See
# scripts/sync.py and bar-design-docs/.../dev_setup_restructured.md for
# the architecture rationale (Phase 1 Tests 4-5, arm iv).
#
# Subcommands:
#   start [--wait-ready]   start the daemon (idempotent; cold-copies first)
#   stop                   SIGTERM the daemon, wait, SIGKILL if needed
#   status                 print PID + alive/dead
#   mirror-engine          one-shot cold copy of just the engine pair
#   logs [-f|...]          tail the sync log
#
# The `start --wait-ready` flow blocks until the daemon's initial cold copy
# has finished and the watcher is up; `bar::launch` uses this to gate
# spring.exe on a quiesced data dir.

set -euo pipefail

: "${DEVTOOLS_DIR:?DEVTOOLS_DIR must be set (Justfile exports it)}"
source "$DEVTOOLS_DIR/scripts/common.sh"

# Watchman, /mnt/c writes, and Windows interop (tasklist.exe etc.) all need
# the WSL host -- not the bar-dev distrobox where watchman's per-user state
# dir is unreadable.
require_host

if [ -z "${BAR_DEVSYNC_DIR:-}" ]; then
  err "BAR_DEVSYNC_DIR not set. Run 'just setup::init' on WSL2 first."
  exit 1
fi

if ! grep -qi microsoft /proc/version 2>/dev/null; then
  err "scripts/sync.sh only runs on WSL2 (target is a Windows-side data dir)."
  exit 1
fi

STATE_DIR="$BAR_DEVSYNC_DIR/.bar-launch"
LOG_FILE="$STATE_DIR/sync.log"
PID_FILE="$STATE_DIR/sync.pid"
READY_FILE="$STATE_DIR/sync.ready"
mkdir -p "$STATE_DIR"

# Source pairs. The watcher's reason for being is the game-content trees
# (Beyond-All-Reason, BYAR-Chobby) that change at edit-loop pace.
#
# Spring's archive scanner registers unpacked-directory archives only when
# the dir has a .sdd suffix (sd7/sdz are compressed forms; sdd is the
# "spring data directory" marker). Without it, scan() walks the dir but
# never adds it to the archive cache.
_compute_source_pairs() {
  local pairs=()
  local missing=()
  local bar_src="$DEVTOOLS_DIR/Beyond-All-Reason"
  local chobby_src="$DEVTOOLS_DIR/BYAR-Chobby"
  local bar_dst="$BAR_DEVSYNC_DIR/games/Beyond-All-Reason.sdd"
  local chobby_dst="$BAR_DEVSYNC_DIR/games/BYAR-Chobby.sdd"

  # `[ -d ]` on a broken symlink returns false; `[ -L ]` is true on the
  # symlink itself regardless of target. We want to distinguish "user
  # never linked it" (silent skip is fine) from "linked but target
  # vanished" (must shout, otherwise edits go to a path the daemon never
  # registered and contributors waste hours wondering why nothing syncs).
  #
  # Inlined per-pair (rather than looping over a joined-string list) on
  # purpose: `IFS=::` is the same as `IFS=:` in bash, so packing
  # name/src/dst into a single string broke the parser silently. Two
  # explicit invocations beat one clever loop.
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

# The engine pair: docker-build-v2 install dir → engine slot. Kept separate
# from the watcher pairs because engine artifacts change at build pace, not
# edit pace; mirrored on demand by `just engine::build`'s post-success hook.
_compute_engine_pair() {
  local engine_src="$DEVTOOLS_DIR/RecoilEngine/build-amd64-windows/install"
  local engine_dst="$BAR_DEVSYNC_DIR/engine/local-build"
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

  # Validate the configured pair list FIRST -- before the "already
  # running" early-return below. Otherwise a stale daemon from a previous
  # session masks broken-symlink errors: the user fixes nothing, runs
  # bar::launch, sees no error, and assumes everything is fine -- but the
  # live daemon doesn't even watch the path they're editing. We want
  # broken config to fail loud every invocation.
  local pair_lines
  if ! pair_lines="$(_compute_source_pairs)"; then
    return 1
  fi

  local existing_pid
  if existing_pid="$(_running_pid)"; then
    # Already-running path: verify pair-list drift before declaring victory.
    # If the live daemon was started with different --pair args than what
    # _compute_source_pairs would produce now (e.g. the user fixed a
    # symlink since the daemon started, or repos.local.conf changed), the
    # daemon is watching a stale tree and edits will silently not sync.
    # Force a restart in that case rather than letting the "all good" log
    # message lie to the user.
    local cmdline live_pairs expected_pairs
    cmdline="$(tr '\0' ' ' < /proc/"$existing_pid"/cmdline 2>/dev/null)"
    # Extract --pair args. tr the cmdline so each arg is space-separated
    # then awk out --pair tokens. Sort both sides for set-equality compare.
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

  # The watcher's pair list is source trees ONLY. The engine pair is
  # intentionally excluded: engine artifacts change at build pace, not edit
  # pace, and a live watcher on the docker-build-v2 install dir races
  # `just engine::build`'s mirror-engine hook -- both paths end up writing
  # the same DLLs, and Windows holds handles to the live install which
  # turns the daemon's on_deleted handlers into Errno 5 storms in the log.
  # Engine sync goes through `cmd_mirror_engine` exclusively.
  # (pair_lines was populated by the upfront validation above, before the
  # "already running" early-return.)
  local pair_args=()
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && pair_args+=(--pair "$p")
  done <<<"$pair_lines"

  # Clear the stale ready flag so --wait-ready can't race against the
  # previous run's marker.
  rm -f "$READY_FILE"

  step "Starting sync daemon (cold-copy + watcher)"
  info "log: $LOG_FILE  (live: just bar::sync-logs -- -F)"
  # Truncate the log on a fresh start so its `tail -f` during --wait-ready
  # below shows only this run's output. Append-mode would surface stale
  # lines from a prior crashed run before any new content lands.
  : >"$LOG_FILE"
  # nohup + & + disown: detach from this shell's job table so we don't
  # SIGHUP the daemon when the caller's terminal closes. Stdout/stderr go
  # to the log file -- sync.py's --log uses an additional stream.
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

  # Stream the daemon log to stderr while we wait. `tail -F` follows even
  # if the file is rotated/recreated mid-wait, and survives the truncate
  # that cmd_start does just before launch. We track its PID so we can
  # kill it the moment the daemon signals ready (or dies).
  info "waiting for cold copy to finish (this can be 30-180s on first run)..."
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
  # Wait up to 5s for graceful shutdown; sync.py's signal handler unwinds
  # the Observer and final-drains pending events.
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

# Return 0 (success) if no game/launcher process is holding engine DLLs.
# Echoes the offending process names on stderr if any are found, returns 1.
# We invoke Windows-side `tasklist` because the locks are Windows OS locks
# on `\\wsl$\...\local-build\*.dll`; pgrep/ps in WSL won't see them.
_engine_lock_holders() {
  if ! command -v tasklist.exe &>/dev/null && ! command -v cmd.exe &>/dev/null; then
    # No interop available -- can't check. Caller decides whether to proceed.
    return 0
  fi
  local holders=()
  local proc
  for proc in spring.exe Beyond-All-Reason.exe; do
    # tasklist /nh: no header. /fi imagename: filter exact match. Output
    # lists matching processes one per line; "INFO: No tasks..." means
    # nothing matched. Suppress the "No tasks" stdout line by checking for
    # the proc name in the output.
    if cmd.exe /c "tasklist /nh /fi \"IMAGENAME eq $proc\"" 2>/dev/null \
       | grep -qi "^$proc"; then
      holders+=("$proc")
    fi
  done
  if [ "${#holders[@]}" -gt 0 ]; then
    printf '%s\n' "${holders[@]}"
    return 1
  fi
  return 0
}

cmd_mirror_engine() {
  local engine_pair
  if ! engine_pair="$(_compute_engine_pair)"; then
    warn "no engine build at $DEVTOOLS_DIR/RecoilEngine/build-amd64-windows/install -- skipping mirror"
    return 0
  fi

  # Preflight: any live spring.exe / BAR launcher will hold open handles
  # on the engine DLLs we're about to overwrite. From Linux through drvfs
  # rsync surfaces this as EACCES per file and exits 23, leaving the
  # install with a mixed-version set of DLLs -- exactly the footgun we
  # want to avoid post-build. Refuse the mirror with clear instructions
  # rather than half-do it.
  local holders
  if ! holders="$(_engine_lock_holders)"; then
    err "Cannot mirror engine -- the following Windows process(es) are running and hold the engine DLLs:"
    while IFS= read -r h; do err "  - $h"; done <<<"$holders"
    err "Stop them first, then re-run 'just engine::build windows' (or just 'sync.sh mirror-engine'):"
    err "  just bar::stop                # stops launcher + spring + python"
    err "  taskkill /F /IM spring.exe /T  # manual fallback"
    return 1
  fi

  step "Mirroring engine artifacts to $BAR_DEVSYNC_DIR/engine/local-build"
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
