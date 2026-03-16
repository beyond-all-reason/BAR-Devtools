set export

DEVTOOLS_DIR := justfile_directory()

# Build Recoil engine via docker-build-v2
build *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    build_script="$DEVTOOLS_DIR/RecoilEngine/docker-build-v2/build.sh"
    if [ ! -f "$build_script" ]; then
        err "RecoilEngine not found. Clone it first: just repos::clone extra"
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
    exec "$build_script" {{args}}
