#!/bin/bash
# Custom start.sh for integration tests with local Recoil engine.
# Prefers /bar/engine/_local if mounted; otherwise falls back to the stock
# glob behavior (pick first alphabetically).
set -e

rm -rf "$1/LuaUI/Config"

if [ -x "$1/engine/_local/spring-headless" ]; then
    exec "$1/engine/_local/spring-headless" --isolation --write-dir "$1" "$2"
else
    # Pick first match (same behavior as upstream start.sh when single engine).
    engines=("$1"/engine/*/spring-headless)
    exec "${engines[0]}" --isolation --write-dir "$1" "$2"
fi
