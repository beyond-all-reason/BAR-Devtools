set export

DEVTOOLS_DIR := justfile_directory()

# Build Recoil engine via docker-build-v2.
# On WSL2 the post-build hook mirrors install/ into $BAR_DATA_DIR/engine/
# local-build/ -- the engine pair is mirrored on demand, not watched.
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
    # Refuse early if a *local-build* engine is running. A live local
    # engine has our build target's binaries mmap'd (Linux) / DLLs
    # share-locked (Windows); the install step would corrupt it or fail
    # mid-copy. Path-scoped: launching with a non-local engine (alpha,
    # stable) doesn't trip this -- you can keep playtesting while you
    # rebuild locally.
    case " {{args}} " in
      *" --help "*|*" -h "*) ;;
      *)
        game_dir="${BAR_DATA_DIR:-$(detect_game_dir 2>/dev/null || true)}"
        if [ -n "$game_dir" ] && ! holders="$(_engine_holders "$game_dir")"; then
          err "Cannot build engine -- local-build is currently running:"
          while IFS= read -r h; do err "  - $h"; done <<<"$holders"
          err "Stop it first:"
          err "  just bar::stop"
          exit 1
        fi
        ;;
    esac
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
