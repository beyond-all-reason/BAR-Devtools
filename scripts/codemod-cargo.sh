#!/usr/bin/env bash
# Run cargo commands for bar-lua-codemod, using rust-dev distrobox if cargo isn't on PATH.
set -euo pipefail

DEVTOOLS_DIR="${DEVTOOLS_DIR:?DEVTOOLS_DIR must be set}"
CODEMOD_DIR="$DEVTOOLS_DIR/bar-lua-codemod"

source "$DEVTOOLS_DIR/scripts/common.sh"

cd "$CODEMOD_DIR"

if command -v cargo &>/dev/null; then
    cargo "$@"
elif command -v distrobox &>/dev/null; then
    info "cargo not on PATH, using ${DEVTOOLS_RUST_DISTROBOX:-rust-dev} distrobox..."
    distrobox enter "${DEVTOOLS_RUST_DISTROBOX:-rust-dev}" -- cargo "$@"
else
    err "cargo not found. Install Rust (rustup.rs) or create a rust-dev distrobox."
    exit 1
fi
