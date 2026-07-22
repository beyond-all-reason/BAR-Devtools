#!/usr/bin/env bash
# Run cargo for bar-lua-codemod inside DEVTOOLS_DISTROBOX (bar-dev has rust/cargo).
set -euo pipefail

DEVTOOLS_DIR="${DEVTOOLS_DIR:?DEVTOOLS_DIR must be set}"
CODEMOD_DIR="$DEVTOOLS_DIR/bar-lua-codemod"

source "$DEVTOOLS_DIR/scripts/common.sh"

enter_distrobox "$@"

cd "$CODEMOD_DIR"
cargo "$@"
