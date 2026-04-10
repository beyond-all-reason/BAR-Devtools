set export

DEVTOOLS_DIR := justfile_directory()
RECOIL_DIR   := DEVTOOLS_DIR / "RecoilEngine"
BAR_DIR      := DEVTOOLS_DIR / "Beyond-All-Reason"
LDE_DIR      := DEVTOOLS_DIR / "lua-doc-extractor"

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
    match=$(find "$BAR_DIR/.lux/5.1" -maxdepth 2 -name 'library' -path '*recoil-lua-library*' -type d 2>/dev/null | head -1)
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
        --src "$RECOIL_DIR/rts/{Lua,Rml/SolLua,Sim/Units/Scripts}/**/*.cpp" \
        --dest "$DEST" \
        --repo "https://github.com/beyond-all-reason/RecoilEngine/blob/master" \
        {{flags}}

    LUX_LIB=$(just lua::recoil-lib-path 2>/dev/null || echo "")
    if [ -n "$LUX_LIB" ] && [ -d "$LUX_LIB" ]; then
        info "Copying into lux-installed recoil-lua-library..."
        clean_dir "$LUX_LIB/library"
        mkdir -p "$LUX_LIB/library"
        cp -r "$RECOIL_DIR/rts/Lua/library/"* "$LUX_LIB/library/"
        ok "Updated $LUX_LIB/library/"
        echo "  Run 'just lua::reset' to restore the published version."
    else
        info "Copying into BAR working tree..."
        clean_dir "$BAR_DIR/recoil-lua-library/library"
        mkdir -p "$BAR_DIR/recoil-lua-library/library"
        cp -r "$RECOIL_DIR/rts/Lua/library/"* "$BAR_DIR/recoil-lua-library/library/"
        ok "Updated $BAR_DIR/recoil-lua-library/library/"
    fi

# Generate library then restart LuaLS so the editor picks up changes
library-reload *flags: (library flags)
    -pkill -f lua-language-server
    @echo "LuaLS restarting (editor extension will respawn it)"

# Reset generated Lua library files and restore lux-installed version
reset:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    info "Resetting Lua library in RecoilEngine..."
    cd "$RECOIL_DIR"
    git checkout -- rts/Lua/library/
    git clean -fd rts/Lua/library/
    info "Restoring lux-installed recoil-lua-library..."
    cd "$BAR_DIR"
    lx sync
    just lua::link
    ok "Lua library reset."
