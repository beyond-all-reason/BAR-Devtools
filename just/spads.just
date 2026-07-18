set export

DEVTOOLS_DIR := justfile_directory()
BAR_DIR      := DEVTOOLS_DIR / "Beyond-All-Reason"
COMPOSE_FILE := DEVTOOLS_DIR / "docker-compose.dev.yml"
COMPOSE      := "podman compose -f " + COMPOSE_FILE
MODES_MOUNT  := DEVTOOLS_DIR / "docker" / "spads-modes"

[private]
require-bar:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_repo bar Beyond-All-Reason "Beyond All Reason"

# Export this checkout's game modes to game_modes.json (headless; mirrors BAR CI).
# Optional OUT copies the result there (e.g. a SPADS plugin dir).
export-modes out="": require-bar
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    require_host

    engine="$DEVTOOLS_DIR/RecoilEngine/build-amd64-linux/install/spring-headless"
    if [ ! -x "$engine" ]; then
      err "Headless engine not found at $engine"
      info "Build it: just engine::build linux"
      exit 1
    fi

    # The export startscript pins Quicksilver Remake 1.24; pull it from the data dir.
    game_dir="$(detect_game_dir 2>/dev/null || true)"
    map_src="$(ls "$game_dir"/maps/quicksilver_remake_1.24.sd7 2>/dev/null | head -1 || true)"
    if [ -z "$map_src" ]; then
      err "Export map 'Quicksilver Remake 1.24' not found under ${game_dir:-<data dir>}/maps"
      info "Launch BAR once to fetch maps, or drop quicksilver_remake_1.24.sd7 there."
      exit 1
    fi

    ws="$DEVTOOLS_DIR/.devtools/modes-export"
    rm -rf "$ws"
    mkdir -p "$ws/games" "$ws/maps"
    ln -sfn "$BAR_DIR" "$ws/games/BAR.sdd"
    ln -sfn "$map_src" "$ws/maps/$(basename "$map_src")"
    cp "$BAR_DIR/tools/headless_testing/springsettings.cfg" "$ws/"
    cp "$BAR_DIR/tools/headless_testing/startscript_modes_export.txt" "$ws/"

    step "Exporting game modes (boots spring-headless briefly)"
    # The startscript self-quits via quitforce; timeout is a safety net, and a
    # non-zero exit is expected -- the JSON check below is the real verdict.
    ( cd "$ws" && rm -rf LuaUI/Config && timeout 300 "$engine" --isolation --write-dir "$ws" startscript_modes_export.txt ) || true

    result="$ws/game_modes.json"
    [ -f "$result" ] || { err "Export produced no game_modes.json (see engine output above)"; exit 1; }
    cats="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("categories",{})))' "$result" 2>/dev/null || echo '?')"
    ok "Exported $cats mode categories -> $result"

    if [ -n "{{out}}" ]; then
      cp "$result" "{{out}}"
      ok "Copied to {{out}}"
    fi

# Stage this checkout's modes into the running SPADS autohost. The ModeCommand
# plugin then serves them (via a file:// override) instead of the published asset.
stage-modes:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_host
    compose="$(spads_compose)"
    just spads::export-modes "{{MODES_MOUNT}}/game_modes-local.json"
    write_env_key SPADS_LOCAL_MODES "1"
    export SPADS_LOCAL_MODES="1"
    step "Recreating SPADS to load the staged modes"
    $compose --profile spads up -d --force-recreate spads
    # up -d returns at container start, but SPADS dies ~15s in if it can't
    # provision its game -- poll a window and fail if it exits.
    info "Waiting for SPADS to settle..."
    for _ in $(seq 1 12); do
      sleep 2
      if ! $compose --profile spads ps --services --status running 2>/dev/null | grep -qx spads; then
        err "SPADS exited after starting -- modes are staged but not being served."
        info "Check why: just services::logs spads"
        exit 1
      fi
    done
    ok "Staged local modes -- SPADS serves them for any hosted version (!mode)."
    info "Revert with: just spads::unstage-modes"

# Remove staged modes; SPADS reverts to the published game-modes lookup.
unstage-modes:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_host
    compose="$(spads_compose)"
    rm -f "{{MODES_MOUNT}}"/*.json
    write_env_key SPADS_LOCAL_MODES ""
    export SPADS_LOCAL_MODES=""
    step "Recreating SPADS to drop the staged modes"
    $compose --profile spads up -d --force-recreate spads
    ok "Reverted -- SPADS now uses the published game-modes lookup."
