#!/usr/bin/env bash
# Deterministic restack of the mission api stack.
#
#   restack.sh rebase    rebase hello_pawns onto upstream/master, then each
#                        branch onto its parent (known auto-resolve:
#                        matchflow_verdict.lua modify/delete -> keep deletion)
#   restack.sh test      run the busted suite as the gate
#   restack.sh push      force-push the stack + sharing-modules to upstream
#   restack.sh all       rebase test
#
# Topology: hello_pawns carries the module foundation (mode_builder); on it,
# matchflow_extraction -> bar_editor and sharing-modules are sibling stacks.
#
# Requires: a clean $BAR_DIR checkout (the script switches branches in it).
# Any conflict other than the known one aborts loudly for manual resolution.
set -euo pipefail

DEVTOOLS_DIR="${DEVTOOLS_DIR:?DEVTOOLS_DIR must be set}"
BAR_DIR="${BAR_DIR:-$DEVTOOLS_DIR/Beyond-All-Reason}"
source "$DEVTOOLS_DIR/scripts/common.sh"

BASE="upstream/master"
STACK=(hello_pawns matchflow_extraction bar_editor)
SHARING="sharing-modules"
KNOWN_DELETE="modules/matchflow/gadgets/matchflow_verdict.lua"

cd "$BAR_DIR"

require_clean() {
    if [ -n "$(git status --porcelain --ignore-submodules | grep -v '^?? ')" ]; then
        echo "ERROR: $BAR_DIR checkout is dirty - commit or stash first." >&2
        exit 1
    fi
}

rebase_one() {
    local branch="$1" onto="$2"
    step "Rebasing $branch onto $onto..."
    git checkout -q "$branch"
    if git rebase "$onto" >/dev/null 2>&1; then
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
            echo "ERROR: unexpected conflict rebasing $branch:" >&2
            git diff --name-only --diff-filter=U >&2
            git rebase --abort
            exit 1
        fi
    done
}

cmd_rebase() {
    require_clean
    git fetch upstream --quiet
    rebase_one "${STACK[0]}" "$BASE"
    local prev="${STACK[0]}"
    for branch in "${STACK[@]:1}"; do
        rebase_one "$branch" "$prev"
        prev="$branch"
    done
    rebase_one "$SHARING" "${STACK[0]}"
}

cmd_test() {
    step "Running busted gate..."
    lx test
    ok "suite green"
}

cmd_push() {
    if [ "$(git merge-base "${STACK[0]}" "$SHARING")" != "$(git rev-parse "${STACK[0]}")" ]; then
        echo "ERROR: $SHARING is not based on ${STACK[0]} - run restack.sh rebase first." >&2
        exit 1
    fi
    step "Pushing stack + $SHARING to upstream (force)..."
    git push -f upstream "${STACK[@]}" "$SHARING"
    ok "pushed"
}

for cmd in "${@:-all}"; do
    case "$cmd" in
        rebase) cmd_rebase ;;
        test) cmd_test ;;
        push) cmd_push ;;
        all) cmd_rebase; cmd_test ;;
        *) echo "usage: restack.sh [rebase|test|push|all]" >&2; exit 1 ;;
    esac
done
