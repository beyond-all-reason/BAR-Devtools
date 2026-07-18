set export

DEVTOOLS_DIR := justfile_directory()

# Show symlink status for game directory
status:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    cmd_link

# Symlink repos into the game directory (engine, chobby, bar -- one or more)
create *targets:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    cmd_link {{targets}}

# Remove Devtools symlinks from the game directory (engine, chobby, bar, or all)
unlink target="all":
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    cmd_unlink "{{target}}"
