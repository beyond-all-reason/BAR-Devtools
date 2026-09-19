#!/usr/bin/env bash
# Linear branch stacks: inspect, rebase, push.
#
#   stack.sh status <branch>...   the chain, its PRs, and every push hazard
#   stack.sh rebase <branch>...   back up each branch, then rebase bottom to top
#   stack.sh push   <branch>...   force-push one branch at a time, bottom to top
#
# The stack is the argument list, bottom first. Nothing about any particular
# stack lives here — pass the branches, and set these when the defaults are
# wrong:
#
#   STACK_REMOTE   remote to compare and push against  (default: upstream, else origin)
#   STACK_BASE     what the bottom branch rebases onto (default: <remote>/HEAD)
#   STACK_REPO     owner/name for PR lookups           (default: derived from the remote URL)
#   STACK_DIR      the repo to act on                   (default: $PWD)
#
# rebase and push switch branches in that repo, so it must be clean.
#
# Why push is shaped this way: a batch `git push -f remote a b c` once pushed
# three branches to one coalesced commit, and GitHub read that as the lower PRs
# having merged — one is permanently badged MERGED, another auto-closed, and
# neither can be undone. So: never a batch, always bottom to top, never while
# two branches in the stack share a head commit.
set -euo pipefail

DEVTOOLS_DIR="${DEVTOOLS_DIR:?DEVTOOLS_DIR must be set}"
source "$DEVTOOLS_DIR/scripts/common.sh"

[ $# -ge 2 ] || { echo "usage: stack.sh <status|rebase|push> <branch>... (bottom first)" >&2; exit 1; }
CMD="$1"; shift
STACK=("$@")

cd "${STACK_DIR:-$PWD}" || exit 1
git rev-parse --git-dir >/dev/null 2>&1 || { err "not a git repository: $PWD"; exit 1; }

if [ -z "${STACK_REMOTE:-}" ]; then
    if git remote get-url upstream >/dev/null 2>&1; then STACK_REMOTE=upstream; else STACK_REMOTE=origin; fi
fi
git remote get-url "$STACK_REMOTE" >/dev/null 2>&1 || { err "no such remote: $STACK_REMOTE"; exit 1; }

# owner/name from the remote URL, for PR lookups only; absent is not fatal.
if [ -z "${STACK_REPO:-}" ]; then
    STACK_REPO="$(git remote get-url "$STACK_REMOTE" \
        | sed -E 's#^(git@|https://|ssh://git@)##; s#^[^/:]+[:/]##; s#\.git$##')"
fi

STARTING_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
# Branch names collide with directory names ("modes", "combat"), so every
# command that takes a branch gets an explicit `--` or a pre-resolved sha; a
# bare `git checkout modes` checks out the path and silently stays put.
trap 'git checkout -q "$STARTING_BRANCH" -- 2>/dev/null || true' EXIT

require_clean() {
    if [ -n "$(git status --porcelain --ignore-submodules | grep -v '^?? ')" ]; then
        err "working tree is dirty - commit or stash first."
        exit 1
    fi
}

assert_exists() {
    local missing=0
    for branch in "${STACK[@]}"; do
        git rev-parse --verify --quiet "$branch" >/dev/null || { err "branch $branch does not exist"; missing=1; }
    done
    [ "$missing" -eq 0 ] || exit 1
}

# Every branch must be an ancestor of the next. A break means the stack is not
# the one described, so reporting and pushing refuse to act on it — but rebase
# does not check this, because a broken chain is exactly what it repairs:
# amending a branch mid-stack orphans everything above it by definition.
assert_chain() {
    assert_exists
    local prev="" broken=0
    for branch in "${STACK[@]}"; do
        if [ -n "$prev" ] && ! git merge-base --is-ancestor "$prev" "$branch"; then
            err "$prev is not an ancestor of $branch - the chain is broken"
            broken=1
        fi
        prev="$branch"
    done
    [ "$broken" -eq 0 ] || exit 1
}

# The false-merge guard: two branches at one commit means a push coalesces
# them, and GitHub marks the lower PR MERGED, irreversibly.
assert_distinct_heads() {
    local dupes
    dupes="$(for branch in "${STACK[@]}"; do
                printf '%s %s\n' "$(git rev-parse "$branch")" "$branch"
             done | sort | awk '{ heads[$1] = heads[$1] " " $2; n[$1]++ }
                               END { for (sha in n) if (n[sha] > 1) print sha heads[sha] }')"
    if [ -n "$dupes" ]; then
        err "branches share a head commit - pushing would false-merge a PR:"
        echo "$dupes" >&2
        exit 1
    fi
}

# Know which PRs a push touches before it happens. A remembered PR map is not
# authoritative; ask the host.
show_prs() {
    command -v gh >/dev/null || { warn "gh not found - cannot enumerate PRs"; return; }
    local branch
    for branch in "${STACK[@]}"; do
        printf '  %-24s %s\n' "$branch" \
            "$(gh pr list --repo "$STACK_REPO" --head "$branch" --state open \
                --json number,baseRefName,title \
                --template '{{range .}}#{{.number}} -> {{.baseRefName}}  {{.title}}{{end}}' 2>/dev/null)"
    done
}

resolve_base() {
    if [ -n "${STACK_BASE:-}" ]; then echo "$STACK_BASE"; return; fi
    local head
    head="$(git symbolic-ref --quiet "refs/remotes/$STACK_REMOTE/HEAD" 2>/dev/null || true)"
    if [ -n "$head" ]; then echo "${head#refs/remotes/}"; return; fi
    err "cannot resolve a base: set STACK_BASE (or run: git remote set-head $STACK_REMOTE -a)"
    exit 1
}

cmd_status() {
    assert_chain
    git fetch "$STACK_REMOTE" --quiet 2>/dev/null || warn "could not fetch $STACK_REMOTE"
    echo
    printf '  %-24s %-10s %-9s %s\n' BRANCH HEAD VS-REMOTE SUBJECT
    local branch sha state ahead
    for branch in "${STACK[@]}"; do
        sha="$(git rev-parse --short "$branch")"
        if git rev-parse --verify --quiet "$STACK_REMOTE/$branch" >/dev/null; then
            ahead="$(git rev-list --count "$STACK_REMOTE/$branch".."$branch")"
            state=$([ "$ahead" -eq 0 ] && echo synced || echo "ahead $ahead")
        else
            state="unpushed"
        fi
        printf '  %-24s %-10s %-9s %s\n' "$branch" "$sha" "$state" \
            "$(git log --format=%s -1 "$branch" -- | cut -c1-46)"
    done
    echo
    step "Open PRs by head branch ($STACK_REPO):"
    show_prs
    echo
    assert_distinct_heads
    ok "no two branches share a head commit"
}

cmd_rebase() {
    require_clean
    assert_exists
    git fetch "$STACK_REMOTE" --quiet
    local base stamp branch prev
    base="$(resolve_base)"
    stamp="$(git rev-parse --short "$base")"
    step "Backing up every branch as backup-$stamp-<branch>..."
    for branch in "${STACK[@]}"; do
        git branch -f "backup-$stamp-$branch" "$branch" >/dev/null
    done
    prev="$base"
    for branch in "${STACK[@]}"; do
        # --onto with the recorded parent: a plain rebase walks back past an
        # amended parent and replays commits onto their own successors.
        local onto old_parent
        onto="$(git rev-parse "$prev")"
        old_parent="$(git rev-parse "$branch^")"
        step "Rebasing $branch onto $prev..."
        if ! git rebase --onto "$onto" "$old_parent" "$branch" >/dev/null 2>&1; then
            err "conflict rebasing $branch:"
            git diff --name-only --diff-filter=U >&2
            git rebase --abort 2>/dev/null || true
            exit 1
        fi
        ok "$branch rebased"
        prev="$branch"
    done
    assert_distinct_heads
    ok "stack rebased; backups at backup-$stamp-*"
}

cmd_push() {
    require_clean
    assert_chain
    assert_distinct_heads
    git fetch "$STACK_REMOTE" --quiet
    echo
    warn "About to FORCE-PUSH ${#STACK[@]} branches to $STACK_REMOTE, one at a time, bottom to top."
    warn "These open PRs are affected:"
    show_prs
    echo
    local answer branch
    read -r -p "Type the number of branches to confirm (${#STACK[@]}): " answer
    if [ "$answer" != "${#STACK[@]}" ]; then
        err "not confirmed - nothing pushed"
        exit 1
    fi
    for branch in "${STACK[@]}"; do
        step "Pushing $branch..."
        git push -f "$STACK_REMOTE" "$branch"
        ok "$branch pushed"
    done
    ok "stack pushed bottom to top"
}

case "$CMD" in
    status) cmd_status ;;
    rebase) cmd_rebase ;;
    push)   cmd_push ;;
    *) echo "usage: stack.sh <status|rebase|push> <branch>... (bottom first)" >&2; exit 1 ;;
esac
