set export

# Versioned bulk migrations, adoption-dated, listed in order. Retire an entry
# to [private] ~6 months after adoption; generation recipes are [private] from
# the start.

DEVTOOLS_DIR := justfile_directory()
BAR_DIR      := DEVTOOLS_DIR / "Beyond-All-Reason"
CODEMOD_DIR  := DEVTOOLS_DIR / "bar-lua-codemod"
# Overridable so a prebuilt binary can stand in for a local build — the dev
# image ships one at /usr/local/bin, which is what CI uses instead of spending
# ~2.5 minutes on cargo. A local target/ build still wins by default.
CODEMOD_BIN  := env('CODEMOD_BIN', CODEMOD_DIR / "target" / "release" / "bar-lua-codemod")

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

[private]
require-library:
    just lua::library

# $CREDENTIALS_RUNNER is an opaque command prefix that loads secrets into
# the environment of whatever it wraps. When set, stylua-cleanup-generate runs
# generate-branches.sh through it so subprocesses (notably the parallel
# `claude --print` workers spawned by scripts/codemod/llm-type-triage.sh) inherit
# the loaded credentials. Without this, the workers would run with the
# credential-less env that just/bash inherits and fail at auth.
#
# Write the prefix however your secrets store wants. Tilde expansion is
# applied. Examples:
#
#   # 1Password CLI
#   CREDENTIALS_RUNNER="op run --env-file=~/code/ai.env.op --"
#
#   # Bitwarden CLI
#   CREDENTIALS_RUNNER="bw run --envfile ~/secrets/ai.env --"
#
#   # direnv loader (treats first arg as a directory whose .envrc to apply)
#   CREDENTIALS_RUNNER="direnv exec ~/code/secrets"
#
#   # raw env injection from a sourceable .env-style file
#   CREDENTIALS_RUNNER="env $(grep -v '^#' ~/.config/anthropic/key.env | xargs)"
#
# When unset, the script runs unwrapped — fine for non-AI invocations
# (e.g. `--push` only) where no subprocess actually needs credentials.

# Regenerate fmt, mig-*, and mig branches from origin/master (uses $CREDENTIALS_RUNNER for AI auth)
[private]
stylua-cleanup-generate *args: require-bar require-codemod require-library
    #!/usr/bin/env bash
    set -euo pipefail
    script="$DEVTOOLS_DIR/scripts/codemod/generate-branches.sh"
    if [[ -n "${CREDENTIALS_RUNNER:-}" ]]; then
        # Expand ~ in the prefix (most secrets-wrapper tools don't expand
        # it themselves when invoked through a non-interactive shell).
        expanded="${CREDENTIALS_RUNNER//\~/$HOME}"
        echo "[info] wrapping stylua-cleanup-generate with: $expanded" >&2
        # eval re-parses the prefix so multi-token wrappers like
        # `op run --env-file=path --` keep their structure when prepended.
        eval "exec $expanded bash \"\$script\" {{args}}"
    fi
    exec bash "$script" {{args}}
