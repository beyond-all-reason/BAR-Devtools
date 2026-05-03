#!/usr/bin/env bash
# `just bar::launch` entry point: hand off to bar_debug_launcher.
#
# Linux: ensure Devtools symlinks are in place, ensure the bar-launch venv
# exists, then exec `python -m bar_launch` with the user's flags. Both the GUI
# (no flags) and the headless CLI (--play / --print-cmd / etc.) flow through
# the same entry point.
#
# WSL2: stub. Phase 3 of bar_launch/plan.md replaces this with the real
# Windows-side handoff (sync watcher + cmd.exe shim). For now we exit with a
# clear pointer so contributors don't think the script is broken.
#
# Expects: DEVTOOLS_DIR (exported by the Justfile).

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

# True if a path looks linked-by-Devtools: a symlink (Linux) or, in the future,
# a sync target. For now Linux-only, the WSL2 case is the stub below.
preflight_symlinks() {
  local game_dir
  game_dir="$(detect_game_dir 2>/dev/null)" || true
  if [ -z "$game_dir" ]; then
    warn "Game directory not detected. Set BAR_GAME_DIR or run 'just setup::init' first."
    return 0
  fi

  local missing=()
  [ -L "$game_dir/games/Beyond-All-Reason" ] || [ -d "$game_dir/games/Beyond-All-Reason" ] || missing+=("bar")
  [ -L "$game_dir/games/BYAR-Chobby" ]       || [ -d "$game_dir/games/BYAR-Chobby" ]       || missing+=("chobby")
  [ -L "$game_dir/engine/local-build" ]      || [ -d "$game_dir/engine/local-build" ]      || missing+=("engine")

  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi

  info "Devtools symlinks missing: ${missing[*]}"
  info "Run: just link::create ${missing[*]}"
  info "(continuing; bar-launch will still work for non-local sources like 'rapid://...:test')"
}

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
  if [ -n "$game_dir" ] && [ -e "$game_dir/engine/local-build" ]; then
    if ! _has_flag --engine "${user_args[@]}"; then
      injected+=(--engine local-build)
    fi
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

run_wsl_stub() {
  warn "WSL2 detected. The Windows-side launch path lands in Phase 3."
  info "See bar-design-docs/bar_launch/plan.md (Phase 3 — Mirror the Linux flow on Windows)."
  info "On Linux without WSL2, this recipe runs the launcher end-to-end."
  exit 1
}

if is_wsl; then
  run_wsl_stub
else
  run_linux "$@"
fi
