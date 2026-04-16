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
    enter_distrobox
    cd "$LDE_DIR"
    npm ci && npm run build
    ok "lua-doc-extractor built"

# Generate Lua library from RecoilEngine sources, copy into BAR submodule
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

    info "Copying into BAR submodule..."
    clean_dir "$BAR_DIR/recoil-lua-library/library"
    mkdir -p "$BAR_DIR/recoil-lua-library/library"
    cp -r "$RECOIL_DIR/rts/Lua/library/"* "$BAR_DIR/recoil-lua-library/library/"
    ok "Updated $BAR_DIR/recoil-lua-library/library/"

# Reset generated Lua library files to submodule state
reset:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    info "Resetting Lua library in RecoilEngine..."
    cd "$RECOIL_DIR"
    git checkout -- rts/Lua/library/
    git clean -fd rts/Lua/library/
    info "Resetting BAR submodule..."
    cd "$BAR_DIR"
    git checkout -- recoil-lua-library/
    ok "Lua library reset."
