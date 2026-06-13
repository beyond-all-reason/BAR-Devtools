set export

DEVTOOLS_DIR := justfile_directory()
RECOIL_DIR   := DEVTOOLS_DIR / "RecoilEngine"
BAR_DIR      := DEVTOOLS_DIR / "Beyond-All-Reason"
LDE_DIR      := DEVTOOLS_DIR / "lua-doc-extractor"
COMPOSE_FILE := DEVTOOLS_DIR / "docker-compose.dev.yml"
COMPOSE      := "docker compose -f " + COMPOSE_FILE

# Friendlier name for `library` — same recipe, "build the lua library"
alias build := library

# Build lua-doc-extractor from local checkout
build-lde:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_repo recoil lua-doc-extractor "lua-doc-extractor"
    cd "$LDE_DIR"
    npm ci && npm run build
    ok "lua-doc-extractor built"

# Generate Lua library from RecoilEngine sources, copy into BAR working tree
library *flags: build-lde
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    LIB="$RECOIL_DIR/rts/Lua/library"
    DEST="$LIB/generated"

    info "Cleaning stale generated files..."
    clean_dir "$DEST"
    clean_dir "$LIB/RecoilEngine"

    enter_distrobox
    LDE="node $LDE_DIR/dist/src/cli.js"

    info "Extracting Lua docs..."
    $LDE \
        --src "$RECOIL_DIR/rts/{Lua,Rml/SolLua}/**/*.cpp" \
        --dest "$DEST" \
        --repo "https://github.com/beyond-all-reason/RecoilEngine/blob/master" \
        {{flags}}

    info "Copying into BAR working tree..."
    mkdir -p "$BAR_DIR/recoil-lua-library/library"
    clean_dir "$BAR_DIR/recoil-lua-library/library"
    cp -r "$RECOIL_DIR/rts/Lua/library/"* "$BAR_DIR/recoil-lua-library/library/"
    ok "Updated $BAR_DIR/recoil-lua-library/library/"

# Generate library then restart LuaLS so the editor picks up changes
library-reload *flags: (library flags)
    -pkill -f lua-language-server
    @echo "LuaLS restarting (editor extension will respawn it)"

# Reset generated Lua library files in RecoilEngine.
#
# `git clean -fdx` removes untracked + gitignored files only (`-fd` alone
# skips gitignored, and the generated tree is gitignored). Tracked,
# hand-authored sources like Types.lua, Spring.lua, RulesSyncedCallins.lua
# are untouched.
reset:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    info "Resetting generated Lua library in RecoilEngine..."
    cd "$RECOIL_DIR"
    git clean -fdx rts/Lua/library/ 2>/dev/null || true
    ok "Lua library reset."

# Run the same lua-language-server check that CI runs, via the recoil-docs
# compose service (which already has mise + lua-language-server set up).
# Useful for catching @param/@field references to undefined types before push.
#
# Resets the library tree first so stale outputs from a previous run with a
# different lua-doc-extractor version (e.g. the contexts branch's bucket
# files: synced.lua / unsynced.lua / shared.lua) don't collide with the
# fresh per-file outputs and produce phantom duplicate-doc-field warnings.
check: reset
    #!/usr/bin/env bash
    set -euo pipefail
    # Export HOST_UID/HOST_GID for docker compose's `${HOST_UID}:${HOST_GID}`
    # substitution in docker-compose.dev.yml — `$UID` is a readonly bash
    # builtin we can't `export` to override, hence the prefix. Without
    # this, compose falls back to its 1000:1000 default, and on hosts
    # where the user is uid 1001+ the generated tree ends up unwritable
    # on subsequent runs.
    export HOST_UID="$(id -u)" HOST_GID="$(id -g)"
    {{COMPOSE}} run --rm recoil-docs lua_check
