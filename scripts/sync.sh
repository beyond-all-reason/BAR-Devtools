#!/usr/bin/env bash
# scripts/sync.sh -- WSL-side cold-copy mirror for the dev data dir.
#
# Mirrors WSL Devtools subtrees (Beyond-All-Reason, BYAR-Chobby, the
# RecoilEngine build output) into the Windows-NTFS sync target
# ($BAR_DEVSYNC_DIR) the engine reads from. Invoked synchronously at
# `just bar::launch` (sources) and `just engine::build` (engine).
#
# Originally this script ran a long-lived Windows-side watcher
# (ReadDirectoryChangesW over `\\wsl.localhost\...` UNC paths) so edits
# would propagate live during dev. The watcher turned out to be silently
# non-functional: Plan 9 -- the protocol that backs `\\wsl.localhost\` --
# does NOT forward Linux-side inotify events to Windows. The watcher
# logged "0 mirrored events" across an entire session of editing, with
# all observed propagation actually coming from the cold-copy that runs
# at watcher startup. We dropped the watcher and made cold-copy the
# explicit, synchronous trigger at known sync points.
#
# Usage:
#   scripts/sync.sh once           # cold copy all source pairs + engine if built
#   scripts/sync.sh mirror-engine  # cold copy ONLY the engine pair (build hook)
#   scripts/sync.sh logs [-f]      # tail the sync log
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
  err "scripts/sync.sh only runs on WSL2 (target is a Windows-side data dir)."
  exit 1
fi

if [ -z "${WSL_DISTRO_NAME:-}" ]; then
  err "WSL_DISTRO_NAME not set -- can't compute UNC source paths."
  err "Open a shell from Windows Terminal's WSL profile (it sets this) or"
  err "export WSL_DISTRO_NAME manually."
  exit 1
fi

STATE_DIR="$BAR_DEVSYNC_DIR/.bar-launch"
LOG_FILE="$STATE_DIR/sync.log"
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

# Source pairs the watcher subscribes to. These are the Devtools-checked-out
# game repos that change at edit-loop pace -- the watcher's reason for being.
#
# The engine pair is deliberately NOT here: build artifacts in
# RecoilEngine/build-amd64-windows/install/ change once per `just engine::build`,
# not per-keystroke, AND the watcher's ReadDirectoryChangesW observer over
# Plan9 UNC paths does not forward Linux-side inotify events from inside
# docker-build-v2's writes. The engine is mirrored synchronously by the
# build recipe via `mirror-engine` instead. See _compute_engine_pair.
_compute_source_pairs() {
  local pairs=()
  local bar_src="$DEVTOOLS_DIR/Beyond-All-Reason"
  local chobby_src="$DEVTOOLS_DIR/BYAR-Chobby"

  # Spring's archive scanner registers unpacked-directory archives only when
  # the dir has a .sdd suffix (sd7/sdz are the compressed forms; sdd is the
  # "spring data directory" marker). Without it, scan() walks the dir but
  # never adds it to the archive cache and --menu / --game lookups fail with
  # "Dependent archive '...' not found". Verified empirically on Win11/WSL2.
  local bar_dst="$BAR_DEVSYNC_DIR/games/Beyond-All-Reason.sdd"
  local chobby_dst="$BAR_DEVSYNC_DIR/games/BYAR-Chobby.sdd"

  if [ -d "$bar_src" ]; then
    pairs+=("$(_unc_for "$bar_src")::$(_win_for "$bar_dst")")
  fi
  if [ -d "$chobby_src" ]; then
    pairs+=("$(_unc_for "$chobby_src")::$(_win_for "$chobby_dst")")
  fi

  if [ "${#pairs[@]}" -eq 0 ]; then
    err "No sync sources found. Clone Beyond-All-Reason / BYAR-Chobby."
    return 1
  fi

  printf '%s\n' "${pairs[@]}"
}

# The engine pair, kept separate so we can mirror it on demand from the
# build recipe rather than via the watcher. RecoilEngine source is the
# docker-build-v2 install dir, not the repo root -- the engine binary +
# bundled dlls live in build-amd64-windows/install/. Returns non-zero (and
# prints nothing) if no engine has been built yet.
_compute_engine_pair() {
  local engine_src="$DEVTOOLS_DIR/RecoilEngine/build-amd64-windows/install"
  local engine_dst="$BAR_DEVSYNC_DIR/engine/local-build"
  if [ ! -d "$engine_src" ]; then
    return 1
  fi
  echo "$(_unc_for "$engine_src")::$(_win_for "$engine_dst")"
}

cmd_once() {
  # Use the WSL path directly: WSL interop runs /mnt/c/.../python.exe as a
  # native Windows process and encodes argv correctly. Going through cmd.exe
  # mangles backslashes inside our quoted UNC pair arguments.
  local venv_py_wsl="$BAR_DEVSYNC_DIR/.venv/Scripts/python.exe"
  if [ ! -f "$venv_py_wsl" ]; then
    err "Windows venv python not found at $venv_py_wsl"
    err "Run 'just setup::init' on WSL2 to bootstrap it."
    return 1
  fi
  local sync_py_win
  sync_py_win="$(_win_for "$DEVTOOLS_DIR/scripts/sync.py")"
  local log_win
  log_win="$(_win_for "$LOG_FILE")"

  # `once` includes the engine pair when an engine build exists so a fresh
  # contributor's first invocation mirrors everything in one shot. Per-build
  # incremental engine sync goes through cmd_mirror_engine instead.
  local pair_args=()
  local p
  while IFS= read -r p; do pair_args+=(--pair "$p"); done < <(_compute_source_pairs)
  local engine_pair
  if engine_pair="$(_compute_engine_pair)"; then
    pair_args+=(--pair "$engine_pair")
  fi

  step "Cold copy (one-shot)"
  "$venv_py_wsl" "$sync_py_win" --cold-copy --log "$log_win" "${pair_args[@]}"
  ok "cold copy complete"
}

# One-shot mirror of just the engine artifacts. Invoked from `just engine::build`
# after a successful compile so the patched binary lands in the data dir.
# The source-side watcher can't help here -- ReadDirectoryChangesW over
# Plan9 UNC misses Linux-side inotify events from docker-build-v2's writes.
cmd_mirror_engine() {
  local engine_pair
  if ! engine_pair="$(_compute_engine_pair)"; then
    warn "no engine build at $DEVTOOLS_DIR/RecoilEngine/build-amd64-windows/install -- skipping mirror"
    return 0
  fi
  # Use the WSL path directly: WSL interop runs /mnt/c/.../python.exe as a
  # native Windows process and encodes argv correctly. Going through cmd.exe
  # mangles backslashes inside our quoted UNC pair argument.
  local venv_py_wsl="$BAR_DEVSYNC_DIR/.venv/Scripts/python.exe"
  if [ ! -f "$venv_py_wsl" ]; then
    err "Windows venv python not found at $venv_py_wsl"
    err "Run 'just setup::init' on WSL2 to bootstrap it."
    return 1
  fi
  local sync_py_win
  sync_py_win="$(_win_for "$DEVTOOLS_DIR/scripts/sync.py")"
  local log_win
  log_win="$(_win_for "$LOG_FILE")"

  step "Mirroring engine artifacts to $BAR_DEVSYNC_DIR/engine/local-build"
  "$venv_py_wsl" "$sync_py_win" --cold-copy --log "$log_win" --pair "$engine_pair"
  ok "engine mirrored"
}

cmd_logs() {
  if [ ! -f "$LOG_FILE" ]; then
    info "no log yet at $LOG_FILE -- has 'sync once' run?"
    return 0
  fi
  exec tail "$@" "$LOG_FILE"
}

case "${1:-once}" in
  once)          shift; cmd_once  "$@" ;;
  mirror-engine) shift; cmd_mirror_engine "$@" ;;
  logs)          shift; cmd_logs "$@"  ;;
  *)
    err "Unknown subcommand: $1"
    echo "Usage: scripts/sync.sh {once|mirror-engine|logs}" >&2
    exit 2
    ;;
esac
