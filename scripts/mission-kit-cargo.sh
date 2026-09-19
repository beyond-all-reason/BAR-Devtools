#!/usr/bin/env bash
# Run cargo for bar-mission-kit inside DEVTOOLS_DISTROBOX (bar-dev has rust/cargo).
set -euo pipefail

DEVTOOLS_DIR="${DEVTOOLS_DIR:?DEVTOOLS_DIR must be set}"
KIT_DIR="$DEVTOOLS_DIR/bar-mission-kit"

source "$DEVTOOLS_DIR/scripts/common.sh"

enter_distrobox "$@"

cd "$KIT_DIR"
cargo "$@"
