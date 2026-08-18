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

    [ -z "$(git status --porcelain)" ] || { err "Working tree not clean"; exit 1; }

    for br in "{{base}}" "${branches[@]}"; do
        git rev-parse --verify --quiet "$br^{commit}" >/dev/null || { err "No such branch: $br"; exit 1; }
    done

    prev="${branches[0]}"
    for br in "${branches[@]:1}"; do
        git merge-base --is-ancestor "$prev" "$br" || {
            err "$br is not stacked on $prev - check the order you listed the branches in."
            exit 1
        }
        prev="$br"
    done

    tip="${branches[-1]}"
    step "Rebasing ${#branches[@]} branches onto {{base}}..."
    if ! git rebase --update-refs "{{base}}" "$tip"; then
        git rebase --abort 2>/dev/null || true
        err "Conflict rebasing onto {{base}} - aborted, tree left clean."
        err "To resolve by hand: git -C $dir rebase --update-refs {{base}} $tip"
        exit 1
    fi
    ok "Stack rebased: ${branches[*]}"

    if [ "$push" != 1 ]; then
        info "Push with: just repos::restack {{repo}} {{base}} ${branches[*]} --push"
        exit 0
    fi

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

    step "Force-pushing ${#branches[@]} branches to origin..."
    git push --force-with-lease origin "${branches[@]}"
    ok "Pushed to origin"
