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
    if [ ! -d "$LDE_DIR" ]; then
        err "lua-doc-extractor not found at $LDE_DIR"
        info "Clone it first: just repos::clone extra"
        exit 1
    fi
    cd "$LDE_DIR"
    npm ci && npm run build
    ok "lua-doc-extractor built"

# Resolve the lux-installed path for recoil-lua-library
[private]
recoil-lib-path:
    #!/usr/bin/env bash
    set -euo pipefail
    match=$(find "$BAR_DIR/.lux/5.1" -maxdepth 2 -name 'src' -path '*recoil-lua-library*' -type d 2>/dev/null | head -1)
    if [ -z "$match" ]; then
        echo "$BAR_DIR/.lux/5.1/recoil-lua-library" # fallback before first sync
    else
        dirname "$match"
    fi

# Create symlink from BAR/recoil-lua-library -> lux-installed package
link: recoil-lib-path
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    target=$(just lua::recoil-lib-path)
    link="$BAR_DIR/recoil-lua-library"
    if [ -L "$link" ]; then
        rm "$link"
    elif [ -e "$link" ]; then
        warn "$link exists and is not a symlink, skipping"
        exit 0
    fi
    ln -s "$target" "$link"
    ok "Symlinked $link -> $target"

# Generate Lua library from RecoilEngine sources, copy into lux-installed path
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

    LUX_LIB=$(just lua::recoil-lib-path 2>/dev/null || echo "")
    if [ -n "$LUX_LIB" ] && [ -d "$LUX_LIB" ]; then
        info "Copying into lux-installed recoil-lua-library..."
        clean_dir "$LUX_LIB/src"
        mkdir -p "$LUX_LIB/src"
        cp -r "$RECOIL_DIR/rts/Lua/library/"* "$LUX_LIB/src/"
        ok "Updated $LUX_LIB/src/"
        echo "  Run 'just lua::reset' to restore the published version."
    else
        info "Copying into BAR working tree..."
        mkdir -p "$BAR_DIR/recoil-lua-library/src"
        cp -r "$RECOIL_DIR/rts/Lua/library/"* "$BAR_DIR/recoil-lua-library/src/"
        ok "Updated $BAR_DIR/recoil-lua-library/src/"
    fi

# Generate library then restart LuaLS so the editor picks up changes
library-reload *flags: (library flags)
    -pkill -f lua-language-server
    @echo "LuaLS restarting (editor extension will respawn it)"

# Reset generated Lua library files and restore lux-installed version.
#
# Scope: only the auto-generated tree (rts/Lua/library/generated/ and the
# RecoilEngine subtree the extractor copies in). Hand-authored sources like
# Types.lua, Spring.lua, RulesSyncedCallins.lua etc. are NOT touched —
# `git checkout -- rts/Lua/library/` would have reverted in-progress edits
# to those, which has bitten us before.
reset:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    info "Resetting generated Lua library in RecoilEngine..."
    cd "$RECOIL_DIR"
    # `git clean -fd` removes untracked files (the generated tree is
    # gitignored). `git checkout` is scoped to the subtree paths that ARE
    # tracked there (none today, but safe against future drift).
    git clean -fd rts/Lua/library/generated/ rts/Lua/library/RecoilEngine/ 2>/dev/null || true
    git checkout -- rts/Lua/library/generated/ rts/Lua/library/RecoilEngine/ 2>/dev/null || true
    info "Restoring lux-installed recoil-lua-library..."
    cd "$BAR_DIR"
    lx sync
    just lua::link
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
    {{COMPOSE}} run --rm recoil-docs lua_check
