#!/bin/bash
# start.sh for integration tests: prefer /bar/engine/_local, else first stock engine.
set -e

rm -rf "$1/LuaUI/Config"

if [ -x "$1/engine/_local/spring-headless" ]; then
    exec "$1/engine/_local/spring-headless" --isolation --write-dir "$1" "$2"
else
    engines=("$1"/engine/*/spring-headless)
    exec "${engines[0]}" --isolation --write-dir "$1" "$2"
fi
