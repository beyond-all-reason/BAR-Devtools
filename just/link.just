set export

DEVTOOLS_DIR := justfile_directory()

# Show symlink status for game directory
status:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    cmd_link

# Symlink a repo into the game directory (engine, chobby, or bar)
create target:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    cmd_link "{{target}}"
