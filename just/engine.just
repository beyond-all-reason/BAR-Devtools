set export

DEVTOOLS_DIR := justfile_directory()

# Build Recoil engine via docker-build-v2.
# On WSL2, mirror the built artifacts into BAR_DEVSYNC_DIR/engine/local-build/
# immediately after a successful build. There's no live source watcher (Plan 9
# doesn't forward Linux-side fsevents to ReadDirectoryChangesW), so cold-copy
# at known sync points -- here for the engine, and in `just bar::launch` for
# the game/chobby trees -- is how WSL contributors' edits reach the engine.
build *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_host
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    build_script="$DEVTOOLS_DIR/RecoilEngine/docker-build-v2/build.sh"
    if [ ! -f "$build_script" ]; then
        err "RecoilEngine not found. Clone it first: just repos::clone recoil"
        exit 1
    fi
    if [ -z "{{args}}" ]; then
        err "Usage: just engine::build <platform> [cmake-args...]"
        echo ""
        echo "  Examples:"
        echo "    just engine::build linux"
        echo "    just engine::build linux -DCMAKE_BUILD_TYPE=Release"
        echo "    just engine::build linux -DTRACY_ENABLE=ON"
        echo "    just engine::build --help"
        exit 1
    fi
    bash "$build_script" {{args}}
    # Skip the mirror for `--help` (build.sh prints help and exits 0 without
    # touching install/). Anything else that completes successfully should
    # have refreshed install/, so mirror it through.
    case " {{args}} " in
      *" --help "*|*" -h "*) ;;
      *)
        if is_wsl; then
          bash "$DEVTOOLS_DIR/scripts/sync.sh" mirror-engine
        fi
        ;;
    esac
