#!/usr/bin/env bash
# One-shot prerequisite installer.
#
# Run this BEFORE the first `just setup::init`. It installs `just` itself
# (>= MIN_JUST_VERSION below) to ~/.local/bin and ensures that directory is
# on PATH for future shells. Idempotent: re-running on a system with a
# satisfactory `just` already on PATH is a no-op except for the PATH line
# (which is itself idempotent — guarded by a literal grep).
#
# Why this script exists at all: every Debian/Ubuntu LTS ships an old `just`
# (1.21.0 on Noble) that doesn't parse `mod` syntax (added 1.31) or
# `[confirm("…")]` (added 1.27). `apt install just` produces silent failures
# at `just --list`. The upstream installer at https://just.systems is the
# only reliable path, and it's friendlier to wrap it once here than to ask
# every contributor to copy a multi-line snippet from the README.
#
# Run from a fresh shell:
#   curl -fsSL https://raw.githubusercontent.com/<repo>/<branch>/scripts/bootstrap.sh | bash
# or, if you've already cloned:
#   bash scripts/bootstrap.sh

set -euo pipefail

MIN_JUST_VERSION="1.31.0"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info() { echo "${BLUE}[info]${NC}  $*"; }
ok()   { echo "${GREEN}[ok]${NC}    $*"; }
warn() { echo "${YELLOW}[warn]${NC}  $*"; }
err()  { echo "${RED}[error]${NC} $*" >&2; }

# Compare semver strings. Returns 0 iff $1 >= $2. Pure bash so we don't add
# yet another prereq before installing the actual prereq.
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
  # `just --version` prints e.g. "just 1.40.0".
  just --version 2>/dev/null | awk '{print $2}'
}

ensure_local_bin_on_path() {
  local rc bin="$HOME/.local/bin"
  case "${SHELL:-}" in
    *zsh)  rc="$HOME/.zshrc" ;;
    *)     rc="$HOME/.bashrc" ;;
  esac
  mkdir -p "$bin"
  local line='export PATH="$HOME/.local/bin:$PATH"'
  if ! grep -qxF "$line" "$rc" 2>/dev/null; then
    printf '\n%s\n' "$line" >> "$rc"
    info "Added ~/.local/bin to PATH in $rc"
  fi
  # Make it active for the rest of THIS script too. Future shells pick it
  # up from $rc.
  case ":${PATH}:" in
    *":$bin:"*) ;;
    *) export PATH="$bin:$PATH" ;;
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
    # Re-resolve from PATH so we see the freshly-installed binary.
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
