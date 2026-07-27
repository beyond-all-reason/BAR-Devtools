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
normalize-remotes:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/repos.sh"
    cmd_normalize_remotes

# Apply repos.local.conf to existing checkouts: add fork remotes + switch to configured branch. --force hard-resets each branch to its remote
sync *args="all":
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/repos.sh"
    cmd_sync {{args}}

# Inspect or restack a linear branch stack, bottom branch first
# (stack status a b c | stack rebase a b c | stack push a b c).
# STACK_REMOTE / STACK_BASE / STACK_REPO override the derived defaults.
stack cmd *branches:
    @cd "{{invocation_directory()}}" && bash "$DEVTOOLS_DIR/scripts/stack.sh" {{cmd}} {{branches}}
