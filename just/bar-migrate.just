set export

# Versioned bulk migrations, adoption-dated, listed in order. Retire an entry
# to [private] ~6 months after adoption; generation recipes are [private] from
# the start.

DEVTOOLS_DIR := justfile_directory()
BAR_DIR      := DEVTOOLS_DIR / "Beyond-All-Reason"
CODEMOD_DIR  := DEVTOOLS_DIR / "bar-lua-codemod"
CODEMOD_BIN  := CODEMOD_DIR / "target" / "release" / "bar-lua-codemod"

[private]
require-bar:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_repo bar Beyond-All-Reason "Beyond All Reason"

[private]
require-codemod:
    #!/usr/bin/env bash
    [ -x "{{CODEMOD_BIN}}" ] && exit 0
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    step "bar-lua-codemod not found, building..."
    bash "$DEVTOOLS_DIR/scripts/codemod-cargo.sh" build --release
    ok "Built bar-lua-codemod"

# 2026-07: codemod transforms + stylua (contributors run after rebasing; idempotent)
stylua-cleanup: require-bar require-codemod
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    enter_distrobox
    # Same skip set as .styluaignore: vendored utils, lux/library tool dirs,
    # and mapgenerator (mapinfo_template.lua is a ${}-placeholder template,
    # not valid Lua).
    excludes=(--exclude common/luaUtilities --exclude .lux --exclude recoil-lua-library --exclude mapgenerator)
    step "bracket-to-dot transform..."
    "{{CODEMOD_BIN}}" bracket-to-dot --path "$BAR_DIR" "${excludes[@]}"
    step "rename-aliases transform..."
    "{{CODEMOD_BIN}}" rename-aliases --path "$BAR_DIR" "${excludes[@]}"
    step "detach-bar-modules transform..."
    "{{CODEMOD_BIN}}" detach-bar-modules --path "$BAR_DIR" "${excludes[@]}"
    step "stylua..."
    (cd "$BAR_DIR" && lx --lua-version 5.1 exec stylua .)
    ok "stylua-cleanup complete"
