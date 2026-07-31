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

# Rebase a stacked branch chain root-first (add --push to force-push it after)
restack repo base +branches:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    dir="$DEVTOOLS_DIR/{{repo}}"
    [ -d "$dir/.git" ] || { err "No git repository at $dir"; exit 1; }
    cd "$dir"

    push=0
    branches=()
    for arg in {{branches}}; do
        if [ "$arg" = "--push" ]; then push=1; else branches+=("$arg"); fi
    done
    [ "${#branches[@]}" -gt 0 ] || { err "No branches given"; exit 1; }

    git diff --quiet && git diff --cached --quiet || { err "Working tree not clean"; exit 1; }

    prev_old="" prev_new="{{base}}"
    for br in "${branches[@]}"; do
        old="$(git rev-parse "$br")"
        step "Rebasing $br onto $prev_new..."
        if [ -z "$prev_old" ]; then
            git rebase "$prev_new" "$br" || { err "Conflict in $br. Resolve, 'git rebase --continue', then restack the rest: just repos::restack {{repo}} $br <remaining>"; exit 1; }
        else
            git rebase --onto "$prev_new" "$prev_old" "$br" || { err "Conflict in $br. Resolve, 'git rebase --continue', then restack the rest: just repos::restack {{repo}} $br <remaining>"; exit 1; }
        fi
        prev_old="$old" prev_new="$br"
    done
    ok "Stack rebased: ${branches[*]}"

    if [ "$push" != 1 ]; then
        info "Push with: just repos::restack {{repo}} {{base}} ${branches[*]} --push"
        exit 0
    fi

    # A branch pushed at the same tip as the one below it reads to GitHub as
    # merged: it closes the PR, credits the pusher, and deletes the branch.
    # That cannot be undone - a merged PR will not reopen.
    prev="{{base}}"
    for br in "${branches[@]}"; do
        n="$(git rev-list --count "$prev..$br" --)" || {
            err "Could not compare $prev..$br - refusing to push."
            exit 1
        }
        if [ "$n" = "0" ]; then
            err "$br carries no commits over $prev - refusing to push."
            err "GitHub would read that as merged, close the PR and delete the branch."
            exit 1
        fi
        prev="$br"
    done

    for r in ${REMOTE:-origin}; do
        step "Force-pushing ${#branches[@]} branches to $r..."
        git push --force-with-lease "$r" "${branches[@]}"
        ok "Pushed to $r"
    done
