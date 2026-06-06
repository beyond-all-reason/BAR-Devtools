#!/usr/bin/env bash
# Installs `just` (>= MIN_JUST_VERSION) to ~/.local/bin. Run before the first
# `just setup::init`. Debian/Ubuntu LTS ships a `just` too old for `mod` and
# `[confirm(...)]` syntax, so we use the upstream installer. Idempotent.
#
#   curl -fsSL https://raw.githubusercontent.com/<repo>/<branch>/scripts/bootstrap.sh | bash
#   bash scripts/bootstrap.sh

set -euo pipefail

MIN_JUST_VERSION="1.31.0"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info() { echo "${BLUE}[info]${NC}  $*"; }
ok()   { echo "${GREEN}[ok]${NC}    $*"; }
warn() { echo "${YELLOW}[warn]${NC}  $*"; }
err()  { echo "${RED}[error]${NC} $*" >&2; }

# returns 0 iff $1 >= $2
version_ge() {
  local a="$1" b="$2" IFS=.
  local -a A=($a) B=($b)
  for i in 0 1 2; do
    local av="${A[i]:-0}" bv="${B[i]:-0}"
    (( av > bv )) && return 0
    (( av < bv )) && return 1
  done
  return 0
}

current_just_version() {
  command -v just >/dev/null 2>&1 || return 1
  just --version 2>/dev/null | awk '{print $2}'
}

ensure_local_bin_on_path() {
  local bin="$HOME/.local/bin"
  mkdir -p "$bin"
  case ":${PATH}:" in
    *":$bin:"*) return 0 ;;   # already resolvable -- leave the rc alone
  esac

  local rc
  case "${SHELL:-}" in
    *zsh)  rc="$HOME/.zshrc" ;;
    *)     rc="$HOME/.bashrc" ;;
  esac

  warn "$bin is not on your PATH -- just, bar-launch, and editor tools install there."
  local add=y
  if (exec </dev/tty) 2>/dev/null; then   # openable tty? (node may exist but ENXIO without one)
    printf "  Add it to %s? [Y/n] " "${rc/#$HOME/~}" > /dev/tty
    read -r add < /dev/tty || add=y
  fi
  export PATH="$bin:$PATH"   # this shell works either way, so install_just + setup::init run
  case "${add:-y}" in
    [Nn]*)
      warn "Leaving $rc untouched. Add this yourself or new shells won't find just:"
      warn '  export PATH="$HOME/.local/bin:$PATH"'
      ;;
    *)
      local line='export PATH="$HOME/.local/bin:$PATH"'
      grep -qxF "$line" "$rc" 2>/dev/null || printf '\n%s\n' "$line" >> "$rc"
      info "Added ~/.local/bin to PATH in ${rc/#$HOME/~} -- open a new shell or source it."
      ;;
  esac
}

install_just() {
  info "Installing just to ~/.local/bin via the upstream installer..."
  if ! command -v curl >/dev/null 2>&1; then
    err "curl is required to bootstrap. Install it first:"
    err "  Ubuntu/Debian: sudo apt install -y curl"
    err "  Arch:          sudo pacman -S curl"
    err "  Fedora:        sudo dnf install -y curl"
    exit 1
  fi
  curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh \
    | bash -s -- --to "$HOME/.local/bin" >/dev/null
}

main() {
  echo "${BOLD}BAR-Devtools bootstrap${NC} — ensuring \`just\` >= ${MIN_JUST_VERSION}"
  echo ""

  ensure_local_bin_on_path

  local current
  if current="$(current_just_version)" && version_ge "$current" "$MIN_JUST_VERSION"; then
    ok "just $current already satisfies the minimum (>= $MIN_JUST_VERSION)"
  else
    if [ -n "${current:-}" ]; then
      warn "found just $current, need >= $MIN_JUST_VERSION — upgrading"
    fi
    install_just
    hash -r 2>/dev/null || true
    current="$(current_just_version)" || {
      err "just still not on PATH after install. Open a new shell and re-run, or"
      err "  source ~/.bashrc  (or ~/.zshrc)"
      exit 1
    }
    if version_ge "$current" "$MIN_JUST_VERSION"; then
      ok "Installed just $current"
    else
      err "Installer produced just $current, which is still below $MIN_JUST_VERSION."
      err "Upstream installer may be pinned; check https://just.systems/."
      exit 1
    fi
  fi

  echo ""
  info "Next steps:"
  info "  1. Open a new shell (or 'source ~/.bashrc' / 'source ~/.zshrc')"
  info "  2. cd into the BAR-Devtools checkout"
  info "  3. just setup::init"
}

main "$@"
