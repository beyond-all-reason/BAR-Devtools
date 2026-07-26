#!/usr/bin/env bash
# Deterministic restack of the mission api / multiplayer stack.
#
#   restack.sh status    print the stack, its PRs, and every push hazard
#   restack.sh rebase    back up each branch, then rebase bottom to top
#   restack.sh test      run the busted suite as the gate
#   restack.sh push      force-push, one branch at a time, bottom to top
#   restack.sh all       rebase test
#
# Topology is linear: each branch carries exactly one commit on its parent.
#
#     hello_pawns            mission api 1/5   #8424 (base: master)
#     matchflow_extraction   mission api 2/5   #8464
#     bar_editor             mission api 3/5   #8465
#     combat                 mission api 4/5   #8460
#     cm8_ashfall            mission api 5/5   #8461
#     modes                  multiplayer 1/2   #8462
#     gui_chat_state         precursor commit inside #8463, no PR of its own
#     sharing-v2             multiplayer 2/2   #8463
#
# gui_chat_locals (#8467) is standalone against master and is NOT in the stack.
#
# Why push is shaped this way: a batch `git push -f upstream a b c` once
# force-pushed three branches to one coalesced commit. GitHub read that as the
# lower PRs having merged - #8427 is permanently badged MERGED and #8426
# auto-closed, and neither can be undone. So: never a batch, always bottom to
# top, never while two stack branches share a head commit.
#
# Requires: a clean $BAR_DIR checkout (the script switches branches in it).
# Any conflict other than the known one aborts loudly for manual resolution.
set -euo pipefail

DEVTOOLS_DIR="${DEVTOOLS_DIR:?DEVTOOLS_DIR must be set}"
if [ -z "${BAR_DIR:-}" ]; then
    for candidate in "$DEVTOOLS_DIR/Beyond-All-Reason" "$DEVTOOLS_DIR/../Beyond-All-Reason"; do
        [ -d "$candidate/.git" ] && { BAR_DIR="$(cd "$candidate" && pwd)"; break; }
    done
fi
BAR_DIR="${BAR_DIR:?BAR_DIR must be set - no Beyond-All-Reason checkout found next to DEVTOOLS_DIR}"
source "$DEVTOOLS_DIR/scripts/common.sh"

BASE="upstream/master"
REMOTE="upstream"
REPO="beyond-all-reason/Beyond-All-Reason"
STACK=(
    hello_pawns
    matchflow_extraction
    bar_editor
    combat
    cm8_ashfall
    modes
    gui_chat_state
    sharing-v2
)
KNOWN_DELETE="modules/matchflow/gadgets/matchflow_verdict.lua"

cd "$BAR_DIR"
STARTING_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
# Branch names here collide with directory names ("modes"), so every command
# that takes a branch gets an explicit `--` or a pre-resolved sha; a bare
# `git checkout modes` checks out the path and silently stays on this branch.
trap 'git checkout -q "$STARTING_BRANCH" -- 2>/dev/null || true' EXIT

require_clean() {
    if [ -n "$(git status --porcelain --ignore-submodules | grep -v '^?? ')" ]; then
        err "$BAR_DIR checkout is dirty - commit or stash first."
        exit 1
    fi
}

# Every branch must exist and be an ancestor of the next. A break here means
# the stack is not what this script thinks it is, so refuse to act on it.
assert_chain() {
    local prev="" broken=0
    for branch in "${STACK[@]}"; do
        if ! git rev-parse --verify --quiet "$branch" >/dev/null; then
            err "branch $branch does not exist"
            broken=1
            continue
        fi
        if [ -n "$prev" ] && ! git merge-base --is-ancestor "$prev" "$branch"; then
            err "$prev is not an ancestor of $branch - the chain is broken"
            broken=1
        fi
        prev="$branch"
    done
    [ "$broken" -eq 0 ] || exit 1
}

# The false-merge guard: two stack branches at one commit means a push
# coalesces them, and GitHub marks the lower PR MERGED, irreversibly.
assert_distinct_heads() {
    local dupes
    dupes="$(for branch in "${STACK[@]}"; do
                printf '%s %s\n' "$(git rev-parse "$branch")" "$branch"
             done | sort | awk '{ heads[$1] = heads[$1] " " $2; n[$1]++ }
                               END { for (sha in n) if (n[sha] > 1) print sha heads[sha] }')"
    if [ -n "$dupes" ]; then
        err "stack branches share a head commit - pushing would false-merge a PR:"
        echo "$dupes" >&2
        exit 1
    fi
}

# The handbook rule, encoded: know which PRs a push touches before it happens.
# The remembered PR map is not authoritative - ask GitHub every time.
show_prs() {
    command -v gh >/dev/null || { warn "gh not found - cannot enumerate PRs"; return; }
    local branch
    for branch in "${STACK[@]}"; do
        printf '  %-22s %s\n' "$branch" \
            "$(gh pr list --repo "$REPO" --head "$branch" --state open \
                --json number,baseRefName,title \
                --template '{{range .}}#{{.number}} -> {{.baseRefName}}  {{.title}}{{end}}' 2>/dev/null)"
    done
}

rebase_one() {
    local branch="$1" onto="$2" onto_sha
    onto_sha="$(git rev-parse "$onto")"
    step "Rebasing $branch onto $onto..."
    git checkout -q "$branch" --
    if git rebase "$onto_sha" >/dev/null 2>&1; then
        ok "$branch rebased clean"
        return
    fi
    # Known resolution: the extraction layer deletes matchflow_verdict.lua;
    # anything the lower layers changed in it dies with the file.
    while true; do
        local unmerged
        unmerged="$(git diff --name-only --diff-filter=U)"
        if [ "$unmerged" = "$KNOWN_DELETE" ]; then
            git rm -q "$KNOWN_DELETE"
            if GIT_EDITOR=true git rebase --continue >/dev/null 2>&1; then
                ok "$branch rebased (auto-resolved $KNOWN_DELETE deletion)"
                return
            fi
        else
            err "unexpected conflict rebasing $branch:"
            git diff --name-only --diff-filter=U >&2
            git rebase --abort
            exit 1
        fi
    done
}

cmd_status() {
    assert_chain
    git fetch "$REMOTE" --quiet 2>/dev/null || warn "could not fetch $REMOTE"
    echo
    printf '  %-22s %-10s %-9s %s\n' BRANCH HEAD VS-REMOTE SUBJECT
    local branch sha state ahead
    for branch in "${STACK[@]}"; do
        sha="$(git rev-parse --short "$branch")"
        if git rev-parse --verify --quiet "$REMOTE/$branch" >/dev/null; then
            ahead="$(git rev-list --count "$REMOTE/$branch".."$branch")"
            state=$([ "$ahead" -eq 0 ] && echo synced || echo "ahead $ahead")
        else
            state="unpushed"
        fi
        printf '  %-22s %-10s %-9s %s\n' "$branch" "$sha" "$state" \
            "$(git log --format=%s -1 "$branch" -- | cut -c1-48)"
    done
    echo
    step "Open PRs by head branch:"
    show_prs
    echo
    assert_distinct_heads
    ok "no two branches share a head commit"
}

cmd_rebase() {
    require_clean
    assert_chain
    git fetch "$REMOTE" --quiet
    local stamp branch
    stamp="$(git rev-parse --short "$BASE")"
    step "Backing up every branch as backup-$stamp-<branch>..."
    for branch in "${STACK[@]}"; do
        git branch -f "backup-$stamp-$branch" "$branch" >/dev/null
    done
    rebase_one "${STACK[0]}" "$BASE"
    local prev="${STACK[0]}"
    for branch in "${STACK[@]:1}"; do
        rebase_one "$branch" "$prev"
        prev="$branch"
    done
    assert_distinct_heads
    ok "stack rebased; backups at backup-$stamp-*"
}

cmd_test() {
    step "Running busted gate..."
    lx test
    ok "suite green"
}

cmd_push() {
    require_clean
    assert_chain
    assert_distinct_heads
    git fetch "$REMOTE" --quiet
    echo
    warn "About to FORCE-PUSH ${#STACK[@]} branches to $REMOTE, one at a time, bottom to top."
    warn "These open PRs are affected:"
    show_prs
    echo
    local answer
    read -r -p "Type the number of branches to confirm (${#STACK[@]}): " answer
    if [ "$answer" != "${#STACK[@]}" ]; then
        err "not confirmed - nothing pushed"
        exit 1
    fi
    local branch
    for branch in "${STACK[@]}"; do
        step "Pushing $branch..."
        git push -f "$REMOTE" "$branch"
        ok "$branch pushed"
    done
    ok "stack pushed bottom to top"
}

for cmd in "${@:-all}"; do
    case "$cmd" in
        status) cmd_status ;;
        rebase) cmd_rebase ;;
        test)   cmd_test ;;
        push)   cmd_push ;;
        all)    cmd_rebase; cmd_test ;;
        *) echo "usage: restack.sh [status|rebase|test|push|all]" >&2; exit 1 ;;
    esac
done
