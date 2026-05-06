set export

DEVTOOLS_DIR := justfile_directory()
REPOS_CONF   := DEVTOOLS_DIR / "repos.conf"
REPOS_LOCAL  := DEVTOOLS_DIR / "repos.local.conf"

# Clone or update repos (feature: bar, recoil, teiserver, chobby, spads-source, or all)
clone feature="all":
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/repos.sh"
    cmd_clone "{{feature}}"

# Show status of all configured repositories
status:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/repos.sh"
    cmd_repos

# Pull latest on all cloned repositories
update:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/repos.sh"
    cmd_update

# Normalize remotes to (origin = fork, upstream = canonical). Skips unrecognized layouts.
fixup:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/repos.sh"
    cmd_fixup
