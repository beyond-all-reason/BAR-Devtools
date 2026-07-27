#!/usr/bin/env bash
# Mirror the game's published DSL types into the kit's fixtures, one file per
# module. The kit needs a surface when it runs without a modules tree (its own
# tests, a single-file check), and a hand-maintained copy drifts: a verb renamed
# in the game kept working here because the copy still described the old shape.
#
#   sync-kit-fixtures.sh          refresh
#   sync-kit-fixtures.sh --check  fail if stale (CI/test gate)
set -euo pipefail
DEVTOOLS_DIR="${DEVTOOLS_DIR:?DEVTOOLS_DIR must be set}"
BAR_DIR="${BAR_DIR:-$DEVTOOLS_DIR/Beyond-All-Reason}"
DEST="$DEVTOOLS_DIR/bar-mission-kit/fixtures/modules"
check=0
[ "${1:-}" = "--check" ] && check=1
stale=0
while IFS= read -r src; do
    rel="${src#"$BAR_DIR"/modules/}"
    out="$DEST/$rel"
    mkdir -p "$(dirname "$out")"
    # Strip CRLF so the fixture is stable regardless of the checkout's endings.
    if [ "$check" -eq 1 ]; then
        if ! diff -q <(sed 's/\r$//' "$src") "$out" >/dev/null 2>&1; then
            echo "stale fixture: $rel" >&2
            stale=1
        fi
    else
        sed 's/\r$//' "$src" > "$out"
    fi
done < <(grep -rl "@meta dsl" "$BAR_DIR"/modules/*/types/*.lua | sort)
if [ "$check" -eq 1 ] && [ "$stale" -eq 1 ]; then
    echo "run: just bar::sync-kit-fixtures" >&2
    exit 1
fi
[ "$check" -eq 1 ] && echo "kit fixtures match the game's types" || echo "kit fixtures refreshed"
