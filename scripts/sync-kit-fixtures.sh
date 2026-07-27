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
done < <(grep -rlE "@meta ((mission|mode)_dsl|actions)" "$BAR_DIR"/modules/*/types/*.lua | sort)

# A file still on the old undifferentiated marker publishes into no sandbox at
# all: the kit would simply stop seeing it. Loudly, then.
if orphans="$(grep -rl "@meta dsl$" "$BAR_DIR"/modules/*/types/*.lua 2>/dev/null)"; then
    echo "surfaces on the retired '@meta dsl' marker (use mission_dsl, mode_dsl or actions):" >&2
    echo "$orphans" >&2
    stale=1
fi

# A surface the game deleted must leave the mirror too: the kit compiles these
# in, so a leftover keeps declaring vocabulary nothing publishes any more.
while IFS= read -r fixture; do
    rel="${fixture#"$DEST"/}"
    [ -f "$BAR_DIR/modules/$rel" ] && continue
    if [ "$check" -eq 1 ]; then
        echo "orphaned fixture: $rel" >&2
        stale=1
    else
        rm -f "$fixture"
        echo "removed orphaned fixture: $rel"
    fi
done < <(find "$DEST" -name '*.lua' | sort)

# The kit compiles the mirror in, so a fixture nobody include_str!s is a file
# the kit cannot see: a module publishing new vocabulary would land here and
# still be missing from the editor. The list is generated, never edited.
if ! DEST="$DEST" python3 - "$DEVTOOLS_DIR/bar-mission-kit/src/types.rs" "$check" <<'PYEOF'; then stale=1; fi
import os, pathlib, re, sys

path, check = sys.argv[1], sys.argv[2] == "1"
dest = pathlib.Path(os.environ["DEST"])
files = sorted(str(p.relative_to(dest)) for p in dest.rglob("*.lua"))


def order(rel):
    module, _, name = rel.partition("/")
    # missions declares the base classes every other surface references, and
    # the parser resolves forward references positionally. Within a module the
    # mission sandbox (dsl.lua) parses last: it and mode_dsl.lua can declare
    # the same global — Transfer is both a mode noun and a mission verb — and
    # the flat surface keeps whichever came last, which for editing trigger
    # files must be the mission one.
    return (module != "missions", module, name.endswith("/dsl.lua"), rel)


want = "pub const SNAPSHOTS: &[&str] = &[\n" + "".join(
    f'    include_str!("../fixtures/modules/{rel}"),\n' for rel in sorted(files, key=order)
) + "];"
src = open(path, encoding="utf8").read()
pattern = re.compile(r"pub const SNAPSHOTS: &\[&str\] = &\[.*?\];", re.S)
if pattern.search(src).group(0) == want:
    sys.exit(0)
if check:
    print("stale SNAPSHOTS list in src/types.rs", file=sys.stderr)
    sys.exit(1)
open(path, "w", encoding="utf8").write(pattern.sub(lambda _: want, src, count=1))
PYEOF

if [ "$check" -eq 1 ] && [ "$stale" -eq 1 ]; then
    echo "run: just bar::sync-kit-fixtures" >&2
    exit 1
fi
[ "$check" -eq 1 ] && echo "kit fixtures match the game's types" || echo "kit fixtures refreshed"
