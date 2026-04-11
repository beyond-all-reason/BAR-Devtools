#!/usr/bin/env bash
# Deterministically rebuild fmt, leaf (mig-*), and mig branches.
# Called by: just bar::fmt-mig-generate [--push] [--update-prs]
set -euo pipefail

source "${DEVTOOLS_DIR}/scripts/common.sh"

# ─── Config ──────────────────────────────────────────────────────────────────

CODEMOD="${CODEMOD_BIN:-${DEVTOOLS_DIR}/bar-lua-codemod/target/release/bar-lua-codemod}"
BAR="${BAR_DIR:-${DEVTOOLS_DIR}/Beyond-All-Reason}"
REMOTE="${PUSH_REMOTE:-upstream}"

ORIGIN_REPO="beyond-all-reason/Beyond-All-Reason"
FORK_OWNER="${FORK_OWNER:-$(git -C "$BAR" remote get-url "$REMOTE" 2>/dev/null | sed -n 's|.*[:/]\([^/]*\)/.*|\1|p')}"

MIG_PR="https://github.com/beyond-all-reason/Beyond-All-Reason/pull/7229"

# LLM capstone — fmt-llm. A single capstone branch that sits on top of mig and
# combines a deterministic env layer (cherry-picked from a user-maintained source
# branch) with an LLM-generated type-fix commit.
#
# Branch topology after a successful run:
#   mig                      ← rollup of all transforms (existing)
#   └─ fmt-llm               ← mig + env commits + gen(llm) commit
#
# The env layer lives in the BAR repo on `$LLM_SOURCE_BRANCH` (default:
# fmt-llm-source), maintained like the existing prereq branches
# (detach-bar-modules-env, lux-i18n). build_fmt_llm cherry-picks every commit
# unique to that branch onto a fresh checkout of mig before invoking the LLM.
# If the source branch has drifted from current mig, conflicts surface — the
# script fails fast and the user resolves them on the source branch (rebase
# onto mig) before re-running with --llm-only.
LLM_SOURCE_BRANCH="${LLM_SOURCE_BRANCH:-fmt-llm-source}"
LLM_BRANCH="fmt-llm"
LLM_COMMIT_PREFIX="gen(llm): type-error triage"
LLM_PR=""
LLM_PR_TITLE="[Types] LLM-driven type-error transform capstone"

# Dirty check only on the host -- inside distrobox stdin is piped via enter_distrobox.
if [[ -z "${_DEVTOOLS_IN_DISTROBOX:-}" ]] && [[ -n "$(git -C "$BAR" status --porcelain 2>/dev/null)" ]]; then
    warn "BAR working tree has uncommitted changes."
    warn "They will be discarded by branch checkouts."
    echo -n "Continue? [y/N] "
    read -r answer
    if [[ "$answer" != [yY] ]]; then
        err "Aborted"
        exit 1
    fi
fi

enter_distrobox "$@"

# ─── Transform registry (order matters for the linear mig branch) ────────────
# Each transform has: _branch, _commit, _pr, _prereq, _description
# Transforms with _prereq cherry-pick that branch before running the codemod.
# Optional: run_*, describe_*, post_commit_*, generate_*_pr_body functions.

# Branches cherry-picked onto every leaf and mig branch before any transform.
PREFIX_BRANCHES=("fix_stylua")

TRANSFORMS=("fmt" "bracket_to_dot" "rename_aliases" "detach_bar_modules" "i18n_kikito" "spring_split")

# -- fmt (stylua) -------------------------------------------------------------

fmt_branch="fmt"
fmt_commit="gen(stylua): initial formatting of entire codebase"
fmt_pr="https://github.com/beyond-all-reason/Beyond-All-Reason/pull/7199"
fmt_pr_title="[Style] stylua format entire codebase"
fmt_prereq=""
fmt_description=""

run_fmt() {
    stylua_pass
}

describe_fmt() {
    cat <<'EOF'
# fmt - run stylua across the entire Lua codebase
stylua .
EOF
}

post_commit_fmt() {
    local fmt_hash
    fmt_hash=$(git_bar rev-parse HEAD)
    step "Creating .git-blame-ignore-revs..."
    printf '%s\n' \
        "# $fmt_commit $fmt_pr" \
        "$fmt_hash" \
        > "$BAR/.git-blame-ignore-revs"
    git_bar add .git-blame-ignore-revs
    git_bar commit -m "git-blame-ignore-revs"
}

# -- bracket-to-dot -----------------------------------------------------------

bracket_to_dot_branch="mig-bracket"
bracket_to_dot_commit="gen(bar_codemod): bracket-to-dot"
bracket_to_dot_pr="https://github.com/beyond-all-reason/Beyond-All-Reason/pull/7287"
bracket_to_dot_prereq=""
bracket_to_dot_description=""

run_bracket_to_dot() {
    "$CODEMOD" bracket-to-dot --path "$BAR" --exclude common/luaUtilities
}

describe_bracket_to_dot() {
    cat <<'EOF'
# bracket-to-dot - convert x["y"] to x.y and ["y"] = to y =
bar-lua-codemod bracket-to-dot --path "$BAR_DIR" --exclude common/luaUtilities
EOF
}

# -- rename-aliases ------------------------------------------------------------

rename_aliases_branch="mig-rename-aliases"
rename_aliases_commit="gen(bar_codemod): rename-aliases"
rename_aliases_pr="https://github.com/beyond-all-reason/Beyond-All-Reason/pull/7288"
rename_aliases_prereq=""
rename_aliases_description=""

run_rename_aliases() {
    "$CODEMOD" rename-aliases --path "$BAR" --exclude common/luaUtilities
}

describe_rename_aliases() {
    cat <<'EOF'
# rename-aliases -- deprecated aliases, e.g. GetMyTeamID -> GetLocalTeamID
bar-lua-codemod rename-aliases --path "$BAR_DIR" --exclude common/luaUtilities
EOF
}

# -- detach-bar-modules --------------------------------------------------------

detach_bar_modules_branch="mig-detach-bar-modules"
detach_bar_modules_commit="gen(bar_codemod): detach-bar-modules"
detach_bar_modules_pr="https://github.com/beyond-all-reason/Beyond-All-Reason/pull/7289"
detach_bar_modules_prereq="detach-bar-modules-env"
detach_bar_modules_description=""

run_detach_bar_modules() {
    "$CODEMOD" detach-bar-modules --path "$BAR" --exclude common/luaUtilities
}

describe_detach_bar_modules() {
    cat <<'EOF'
# detach-bar-modules -- moves I18N, Utilities, Debug, Lava, GetModOptionsCopy off the Spring table
bar-lua-codemod detach-bar-modules --path "$BAR_DIR" --exclude common/luaUtilities
EOF
}

# -- spring-split --------------------------------------------------------------

spring_split_branch="mig-spring-split"
spring_split_commit="gen(bar_codemod): spring-split"
spring_split_pr="https://github.com/beyond-all-reason/Beyond-All-Reason/pull/7290"
spring_split_prereq=""
spring_split_description='See [RecoilEngine#2799](https://github.com/beyond-all-reason/RecoilEngine/pull/2799) for the SpringSynced/SpringUnsynced/SpringShared type split on the engine side.'

run_spring_split() {
    local lib="$BAR/recoil-lua-library/library"
    [ -d "$lib" ] || lib="$BAR/recoil-lua-library/src"
    "$CODEMOD" spring-split --path "$BAR" --library "$lib" --exclude common/luaUtilities

    sed -i '/^_G\.GG = /i\
_G.SpringSynced = _G.SpringSynced or _G.Spring\
_G.SpringUnsynced = _G.SpringUnsynced or _G.Spring\
_G.SpringShared = _G.SpringShared or _G.Spring\
' "$BAR/spec/spec_helper.lua"
}

describe_spring_split() {
    cat <<'EOF'
# spring-split - split Spring into SpringSynced, SpringUnsynced, and SpringShared
bar-lua-codemod spring-split --path "$BAR_DIR" --library "$BAR_DIR/recoil-lua-library/src" --exclude common/luaUtilities
EOF
}

# -- i18n-kikito ---------------------------------------------------------------

i18n_kikito_branch="mig-i18n"
i18n_kikito_commit="gen(bar_codemod): i18n-kikito"
i18n_kikito_pr="https://github.com/beyond-all-reason/Beyond-All-Reason/pull/7291"
i18n_kikito_pr_title="[Deps] i18n-kikito"
i18n_kikito_prereq="lux-i18n"
i18n_kikito_description=""

run_i18n_kikito() {
    rm -rf "$BAR/modules/i18n/i18nlib"
    "$CODEMOD" i18n-kikito --path "$BAR"
}

describe_i18n_kikito() {
    cat <<'EOF'
# i18n-kikito - replace vendored gajop/i18n fork with kikito/i18n.lua, rewrite call sites
bar-lua-codemod i18n-kikito --path "$BAR_DIR"
EOF
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

tvar() { eval echo "\${${1}_${2}:-}"; }

declare -A TEST_RESULTS

host_exec() {
    if [ -f /run/.containerenv ] && command -v distrobox-host-exec &>/dev/null; then
        distrobox-host-exec "$@"
    else
        "$@"
    fi
}

git_bar() { host_exec git -C "$BAR" "$@"; }

gh_host() { host_exec gh "$@"; }

stylua_pass() {
    step "Running stylua..."
    (cd "$BAR" && stylua .)
}

run_tests() {
    local branch="$1"
    step "Running unit tests on $branch..."
    if (cd "$BAR" && lx --lua-version 5.1 test); then
        TEST_RESULTS["$branch"]="pass"
        ok "Units passed on $branch"
    else
        TEST_RESULTS["$branch"]="fail"
        warn "Units failed on $branch"
    fi
}

diff_stat() {
    local raw
    raw=$(git_bar diff --shortstat "$1..$2" 2>/dev/null || true)
    if [[ -z "$raw" ]]; then
        echo "no changes"
        return
    fi
    local files ins del
    files=$(echo "$raw" | grep -oP '\d+(?= file)' || echo "0")
    ins=$(echo "$raw" | grep -oP '\d+(?= insertion)' || echo "0")
    del=$(echo "$raw" | grep -oP '\d+(?= deletion)' || echo "0")
    echo "${files} files, +${ins} −${del}"
}

# Run emmylua_check and return the error count from its summary line.
# Returns "0" if the analyzer reports no errors (or if the analyzer can't be reached).
emmylua_error_count() {
    local out count
    out=$(cd "$BAR" && emmylua_check -c .emmyrc.json . 2>&1 || true)
    count=$(echo "$out" | grep -oP '^\s*\K\d+(?= errors?$)' | head -1)
    echo "${count:-0}"
}

# ─── PR body generators ─────────────────────────────────────────────────────

pr_link() {
    local label="$1" url="$2"
    if [[ -n "$url" ]]; then
        echo "[$label]($url)"
    else
        echo "$label"
    fi
}

unit_status() {
    local branch="$1"
    local status="${TEST_RESULTS["$branch"]:-n/a}"
    if [[ "$status" == "pass" ]]; then
        echo "✅ pass"
    elif [[ "$status" == "fail" ]]; then
        echo "❌ FAIL"
    else
        echo "n/a"
    fi
}

generate_topology() {
    echo "### Branch Topology"
    echo ""
    echo "All branches regenerated deterministically by [\`just bar::fmt-mig-generate\`](https://github.com/beyond-all-reason/BAR-Devtools/pull/17)."
    echo ""
    echo "*Generated $(date -u +"%Y-%m-%d %H:%M:%S UTC")*"
    echo ""
    echo "**Standalone branches** (each targets \`master\`, can merge independently):"
    echo ""
    echo "| Branch | Transform | Diff vs \`master\` | Units |"
    echo "|--------|-----------|------|-------|"
    for transform in "${TRANSFORMS[@]}"; do
        local branch pr_url stats
        branch=$(tvar "$transform" "branch")
        pr_url=$(tvar "$transform" "pr")
        stats=$(diff_stat origin/master "$branch")
        echo "| $(pr_link "$branch" "$pr_url") | \`${transform//_/-}\` | $stats | $(unit_status "$branch") |"
    done
    echo ""
    echo "**Combined branch** (stylua + all transforms — full preview):"
    echo ""
    echo "| Branch | Diff vs \`master\` | Units |"
    echo "|--------|------|-------|"
    echo "| $(pr_link "mig" "$MIG_PR") | $(diff_stat origin/master mig) | $(unit_status mig) |"
}

generate_leaf_pr_body() {
    local transform="$1" output_file="$2"
    local description
    description=$(tvar "$transform" "description")

    echo "Part of [BAR Lua formatting migration]($MIG_PR). Autogenerated by [\`just bar::fmt-mig-generate\`](https://github.com/beyond-all-reason/BAR-Devtools/pull/17)."
    echo ""

    if [[ -n "$description" ]]; then
        echo "$description"
        echo ""
    fi

    cat <<HEADER
### Generated by

\`\`\`sh
HEADER
    "describe_${transform}"
    cat <<'MIDDLE'
```

### Rebasing in-flight branches

```bash
git fetch origin && git rebase origin/master
# at each conflict:
git checkout --theirs <conflicted-files>
just bar::fmt-mig
git add -A && git rebase --continue
```

MIDDLE

    echo '### Output'
    echo ""
    echo '```'
    cat "$output_file"
    echo '```'
    echo ""
    generate_topology
}

generate_mig_pr_body() {
    local output_file="$1"

    echo "Combined preview: \`stylua .\` formatting + all AST transforms applied sequentially. Autogenerated by [\`just bar::fmt-mig-generate\`](https://github.com/beyond-all-reason/BAR-Devtools/pull/17)."
    echo ""

    echo "### Transforms"
    echo ""
    for transform in "${TRANSFORMS[@]}"; do
        local pr_url
        pr_url=$(tvar "$transform" "pr")
        if [[ -n "$pr_url" ]]; then
            echo "* [\`${transform//_/-}\`]($pr_url) -- $(describe_${transform} | head -1 | sed 's/^# [^ ]* - //')"
        else
            echo "* \`${transform//_/-}\` -- $(describe_${transform} | head -1 | sed 's/^# [^ ]* - //')"
        fi
    done

    cat <<'MID'

### Rebasing in-flight branches

```bash
git fetch origin && git rebase origin/master
# at each conflict:
git checkout --theirs <conflicted-files>
just bar::fmt-mig
git add -A && git rebase --continue
```

MID

    echo '### Output'
    echo ""
    echo '```'
    cat "$output_file"
    echo '```'
    echo ""
    generate_topology
}

# ─── Build phase (no PR body generation — branches must all exist first) ─────

# Cherry-pick origin/master..<branch>, but skip silently if the branch has no
# commits unique vs origin/master (e.g. a prefix branch that has been merged
# upstream and rebased to empty). Without this guard `git cherry-pick` aborts
# the entire pipeline with "empty commit set passed".
cherry_pick_prefix() {
    local prefix="$1"
    local count
    count=$(git_bar rev-list --count "origin/master..$prefix" 2>/dev/null || echo 0)
    if [[ "$count" == "0" ]]; then
        info "  (skip) $prefix has no commits unique vs origin/master"
        return 0
    fi
    git_bar cherry-pick "origin/master..$prefix"
}

build_leaf() {
    local transform="$1"
    local branch commit_msg prereq
    branch=$(tvar "$transform" "branch")
    commit_msg=$(tvar "$transform" "commit")
    prereq=$(tvar "$transform" "prereq")

    step "Building leaf: $branch"
    git_bar checkout --force -B "$branch" origin/master

    for prefix in "${PREFIX_BRANCHES[@]}"; do
        cherry_pick_prefix "$prefix"
    done

    if [[ -n "$prereq" ]]; then
        step "Cherry-picking prereq commits from $prereq..."
        cherry_pick_prefix "$prereq"
    fi

    local output_file="$BAR/.git/${branch}-output.txt"
    "run_${transform}" 2>&1 | tee "$output_file"

    git_bar add -A
    git_bar commit -m "$commit_msg"

    if type "post_commit_${transform}" &>/dev/null; then
        "post_commit_${transform}"
    fi

    run_tests "$branch"

    ok "Leaf $branch ready"
}

build_mig() {
    step "Building linear mig branch..."
    git_bar checkout --force -B mig origin/master

    for prefix in "${PREFIX_BRANCHES[@]}"; do
        cherry_pick_prefix "$prefix"
    done

    local -A mig_prereqs_picked
    for transform in "${TRANSFORMS[@]}"; do
        local prereq
        prereq=$(tvar "$transform" "prereq")
        if [[ -n "$prereq" ]] && [[ -z "${mig_prereqs_picked["$prereq"]:-}" ]]; then
            step "Cherry-picking prereq commits from $prereq..."
            cherry_pick_prefix "$prereq"
            mig_prereqs_picked["$prereq"]=1
        fi
    done

    local mig_output_file="$BAR/.git/mig-output.txt"
    : > "$mig_output_file"
    local transform_hashes=()

    for transform in "${TRANSFORMS[@]}"; do
        local commit_msg
        commit_msg=$(tvar "$transform" "commit")
        step "mig: $transform"
        "run_${transform}" 2>&1 | tee -a "$mig_output_file"
        stylua_pass
        git_bar add -A
        git_bar commit -m "$commit_msg"
        transform_hashes+=("$(git_bar rev-parse HEAD)")
    done

    step "Adding transform commits to .git-blame-ignore-revs..."
    : > "$BAR/.git-blame-ignore-revs"
    for i in "${!TRANSFORMS[@]}"; do
        local transform="${TRANSFORMS[$i]}"
        local commit_msg
        commit_msg=$(tvar "$transform" "commit")
        printf '# %s\n%s\n\n' "$commit_msg" "${transform_hashes[$i]}" \
            >> "$BAR/.git-blame-ignore-revs"
    done
    git_bar add .git-blame-ignore-revs
    git_bar commit -m "git-blame-ignore-revs: add transform commits"

    run_tests "mig"

    ok "mig branch ready ($((${#TRANSFORMS[@]} + 1)) commits)"
}

# ─── LLM capstone (runs after build_mig) ─────────────────────────────────────

# Recover from a failed prior run that left the BAR repo in a partial git
# operation (cherry-pick, rebase, or merge in progress). Called defensively
# before any git state change in build_fmt_llm.
abort_stuck_git_state() {
    local bar_git="$BAR/.git"
    if [[ -f "$bar_git/CHERRY_PICK_HEAD" ]] || [[ -d "$bar_git/sequencer" ]]; then
        warn "Found in-progress cherry-pick in BAR repo — aborting"
        git_bar cherry-pick --abort 2>/dev/null || true
        rm -rf "$bar_git/sequencer" 2>/dev/null || true
    fi
    if [[ -d "$bar_git/rebase-merge" ]] || [[ -d "$bar_git/rebase-apply" ]]; then
        warn "Found in-progress rebase in BAR repo — aborting"
        git_bar rebase --abort 2>/dev/null || true
    fi
    if [[ -f "$bar_git/MERGE_HEAD" ]]; then
        warn "Found in-progress merge in BAR repo — aborting"
        git_bar merge --abort 2>/dev/null || true
    fi
    # Blow away any leftover untracked files that were dropped by a mid-
    # cherry-pick abort — they will be regenerated by the normal flow.
    git_bar --no-optional-locks -c submodule.recurse=false reset --hard HEAD 2>/dev/null || true
}

# Build fmt-llm by:
#   1. Replaying env commits from $LLM_SOURCE_BRANCH onto current mig using
#      `git rebase --onto mig <stored_base> fmt-llm-source`. The stored base
#      is the mig SHA that fmt-llm-source was last rebased onto, tracked in
#      git config branch.fmt-llm-source.migBase.
#   2. Checking out fmt-llm from the rebased source branch
#   3. Invoking the LLM orchestrator (drives just bar::check errors → 0)
#   4. Committing whatever the orchestrator edited as one gen(llm) commit
#   5. Updating the stored migBase to the new mig SHA for next run
#
# The source branch is user-maintained, like detach-bar-modules-env / lux-i18n.
# Bootstrap once with:
#     git -C $BAR branch fmt-llm-source <env-commit-sha>
#     git -C $BAR config branch.fmt-llm-source.migBase <parent-of-env-commit>
#
# Subsequent env edits: check out fmt-llm-source, amend or add commits on top.
# No need to manually rebase — this function handles mig drift automatically.
build_fmt_llm() {
    abort_stuck_git_state

    if ! git_bar rev-parse --verify "$LLM_SOURCE_BRANCH" >/dev/null 2>&1; then
        err "LLM source branch '$LLM_SOURCE_BRANCH' not found in BAR repo"
        err ""
        err "Bootstrap it from an existing env commit (one-time setup), e.g.:"
        err "  git -C $BAR branch $LLM_SOURCE_BRANCH <env-commit-sha>"
        err "  git -C $BAR config branch.$LLM_SOURCE_BRANCH.migBase <parent-sha>"
        err ""
        err "Or create a fresh env commit on top of mig:"
        err "  git -C $BAR checkout -b $LLM_SOURCE_BRANCH mig"
        err "  # ...edit .emmyrc.json, types/*, etc..."
        err "  git -C $BAR commit -am 'env(llm): emmylua config + type stubs'"
        err "  git -C $BAR config branch.$LLM_SOURCE_BRANCH.migBase mig"
        exit 1
    fi

    # Look up the stored mig base (the mig SHA fmt-llm-source was last rebased
    # onto). This lets `rebase --onto` cleanly replay just the env commits even
    # when every transform SHA has changed.
    local stored_base new_mig_sha
    stored_base=$(git_bar config --get "branch.$LLM_SOURCE_BRANCH.migBase" 2>/dev/null || true)
    new_mig_sha=$(git_bar rev-parse mig)

    if [[ -z "$stored_base" ]]; then
        # Fall back: assume the env commits are the single tip of the source
        # branch (the typical case). Base = parent of the source branch tip.
        stored_base=$(git_bar rev-parse "$LLM_SOURCE_BRANCH^" 2>/dev/null || true)
        if [[ -z "$stored_base" ]]; then
            err "Cannot determine env-commit base for $LLM_SOURCE_BRANCH"
            err "Set it manually:"
            err "  git -C $BAR config branch.$LLM_SOURCE_BRANCH.migBase <parent-of-env-commit-sha>"
            exit 1
        fi
        warn "No migBase config for $LLM_SOURCE_BRANCH; assuming single-commit env layer"
        warn "  inferred base: $stored_base (parent of $LLM_SOURCE_BRANCH tip)"
    fi

    local env_commit_count
    env_commit_count=$(git_bar rev-list --count "$stored_base..$LLM_SOURCE_BRANCH")
    step "Rebasing $env_commit_count env commit(s) from $LLM_SOURCE_BRANCH onto mig..."
    step "  old base: $stored_base"
    step "  new mig:  $new_mig_sha"

    if [[ "$env_commit_count" == "0" ]]; then
        warn "$LLM_SOURCE_BRANCH has no env commits (migBase == source tip) — env layer is empty"
        git_bar checkout --force -B "$LLM_BRANCH" mig
    else
        # Replay env commits onto new mig. --onto uses the stored base as the
        # "upstream" so only commits AFTER it are replayed.
        if ! git_bar rebase --onto mig "$stored_base" "$LLM_SOURCE_BRANCH"; then
            err ""
            err "Rebase conflict replaying $LLM_SOURCE_BRANCH env commits onto mig."
            err "This usually means an env-layer file (e.g. types/Spring.lua) was"
            err "also modified by a transform on mig. Resolve in place:"
            err ""
            err "  cd $BAR"
            err "  # ...resolve conflicts in marked files..."
            err "  git add -A && git rebase --continue"
            err "  git config branch.$LLM_SOURCE_BRANCH.migBase $new_mig_sha"
            err "  cd $DEVTOOLS_DIR && just bar::fmt-mig-generate --llm-only"
            err ""
            err "Or abort the rebase and re-create the env commit on top of new mig:"
            err "  cd $BAR && git rebase --abort"
            err "  git branch -f $LLM_SOURCE_BRANCH mig"
            err "  git checkout $LLM_SOURCE_BRANCH"
            err "  # ...re-apply env edits..."
            err "  git commit -am 'env(llm): emmylua config + type stubs'"
            err "  git config branch.$LLM_SOURCE_BRANCH.migBase mig"
            exit 1
        fi

        # fmt-llm-source is now a clean "mig + env" branch. fmt-llm starts
        # from it directly — no further cherry-picking needed.
        git_bar checkout --force -B "$LLM_BRANCH" "$LLM_SOURCE_BRANCH"
    fi

    # Record the new base for next run. Done AFTER successful rebase so a
    # failure doesn't poison the stored pointer.
    git_bar config "branch.$LLM_SOURCE_BRANCH.migBase" "$new_mig_sha"

    # ── LLM layer: invoke the orchestrator and commit its edits ──
    local before
    before=$(emmylua_error_count)
    step "$LLM_BRANCH pre-orchestrator errors: $before"

    if [[ "$before" == "0" ]]; then
        ok "$LLM_BRANCH already at zero errors — skipping orchestrator"
    else
        host_exec bash "${DEVTOOLS_DIR}/scripts/llm-type-triage.sh"
    fi

    local after
    after=$(emmylua_error_count)
    step "$LLM_BRANCH post-orchestrator errors: $after"

    git_bar add -A
    if git_bar diff --cached --quiet; then
        warn "Orchestrator produced no edits — skipping LLM commit"
    else
        git_bar commit -m "$LLM_COMMIT_PREFIX ($before → $after errors)

Generated by claude-opus-4-6 orchestrator dispatching parallel
claude-sonnet-4-6 subagents per SKILL.md fix categories.
See BAR-Devtools/claude/prompts/orchestrator.md for the workflow."
    fi

    run_tests "$LLM_BRANCH"

    ok "$LLM_BRANCH ready"
}

# ─── PR body + update phase (runs after all branches exist) ──────────────────

generate_all_pr_bodies() {
    step "Generating PR bodies (with diff stats)..."

    # Leaf PR bodies only emitted in full pipeline (--llm-only skips leaves).
    if [[ "${DO_LLM_ONLY:-false}" != "true" ]]; then
        for transform in "${TRANSFORMS[@]}"; do
            local branch output_file pr_body_file
            branch=$(tvar "$transform" "branch")
            output_file="$BAR/.git/${branch}-output.txt"
            pr_body_file="$BAR/.git/${branch}-pr-body.md"
            if type "generate_${transform}_pr_body" &>/dev/null; then
                "generate_${transform}_pr_body" > "$pr_body_file"
            else
                generate_leaf_pr_body "$transform" "$output_file" > "$pr_body_file"
            fi
            ok "  $branch PR body: $pr_body_file"
        done

        local mig_output_file="$BAR/.git/mig-output.txt"
        pr_body_file="$BAR/.git/mig-pr-body.md"
        generate_mig_pr_body "$mig_output_file" > "$pr_body_file"
        ok "  mig PR body: $pr_body_file"
    fi

    # LLM capstone PR body (only generated when fmt-llm exists).
    if git_bar rev-parse --verify "$LLM_BRANCH" >/dev/null 2>&1; then
        pr_body_file="$BAR/.git/${LLM_BRANCH}-pr-body.md"
        generate_llm_pr_body > "$pr_body_file"
        ok "  $LLM_BRANCH PR body: $pr_body_file"
    fi
}

generate_llm_pr_body() {
    local final_count summary_file env_commit_count
    final_count=$(emmylua_error_count)
    summary_file="$BAR/.git/llm-triage-summary.txt"
    env_commit_count=$(git_bar rev-list --count "mig..$LLM_BRANCH" 2>/dev/null || echo "?")

    cat <<EOF
LLM-driven type-error triage capstone. Stacks two layers on top of [\`mig\`]($MIG_PR):

1. **Env layer** — \`$env_commit_count\` commit(s) cherry-picked from
   \`$LLM_SOURCE_BRANCH\`, supplying \`.emmyrc.json\` sandbox globals,
   \`types/*.lua\` stubs, and systemic annotation parser fixes (SKILL.md
   categories 39–42). Maintained like the existing prereq branches
   (\`detach-bar-modules-env\`, \`lux-i18n\`).
2. **LLM layer** — one \`gen(llm)\` commit produced by an Opus 4.6
   orchestrator dispatching parallel Sonnet 4.6 subagents per the fix
   categories in [\`claude/skills/codemod-prereq/SKILL.md\`](https://github.com/beyond-all-reason/BAR-Devtools/blob/master/claude/skills/codemod-prereq/SKILL.md).

### Diff vs \`mig\`

$(diff_stat mig "$LLM_BRANCH")

### emmylua_check on this branch

$final_count errors

EOF

    if [[ -f "$summary_file" ]]; then
        echo '### Run summary'
        echo ''
        echo '```'
        cat "$summary_file"
        echo '```'
        echo ''
    fi
}

update_prs() {
    if [[ "${DO_LLM_ONLY:-false}" != "true" ]]; then
        for transform in "${TRANSFORMS[@]}"; do
            local branch pr_url pr_body_file pr_title
            branch=$(tvar "$transform" "branch")
            pr_url=$(tvar "$transform" "pr")
            pr_body_file="$BAR/.git/${branch}-pr-body.md"
            pr_title=$(tvar "$transform" "pr_title")
            : "${pr_title:="[Types] ${transform//_/-}"}"

            if [[ -n "$pr_url" ]]; then
                step "Updating PR $pr_url..."
                gh_host pr edit "$pr_url" --body-file "$pr_body_file"
                ok "PR updated"
            else
                step "Creating PR for $branch..."
                local new_url
                new_url=$(gh_host pr create \
                    --repo "$ORIGIN_REPO" \
                    --head "$FORK_OWNER:$branch" \
                    --base master \
                    --title "$pr_title" \
                    --body-file "$pr_body_file" \
                    --draft)
                ok "Created PR: $new_url"
                warn "Add this URL to generate-branches.sh: ${transform}_pr=\"$new_url\""
            fi
        done

        if [[ -n "$MIG_PR" ]]; then
            step "Updating mig PR $MIG_PR..."
            gh_host pr edit "$MIG_PR" --body-file "$BAR/.git/mig-pr-body.md"
            ok "mig PR updated"
        fi
    fi

    # fmt-llm capstone PR (only one branch — env layer is folded into it).
    update_capstone_pr "$LLM_BRANCH" "$LLM_PR" "$LLM_PR_TITLE"
}

update_capstone_pr() {
    local branch="$1" pr_url="$2" pr_title="$3"
    local pr_body_file="$BAR/.git/${branch}-pr-body.md"

    if ! git_bar rev-parse --verify "$branch" >/dev/null 2>&1; then
        return 0
    fi
    if [[ ! -f "$pr_body_file" ]]; then
        warn "$branch: PR body not generated, skipping"
        return 0
    fi

    # fmt-llm targets mig (showing env layer + LLM commit as a unified diff).
    local base="mig"

    if [[ -n "$pr_url" ]]; then
        step "Updating PR $pr_url..."
        gh_host pr edit "$pr_url" --body-file "$pr_body_file"
        ok "$branch PR updated"
    else
        step "Creating PR for $branch (base: $base)..."
        local new_url
        new_url=$(gh_host pr create \
            --repo "$ORIGIN_REPO" \
            --head "$FORK_OWNER:$branch" \
            --base "$base" \
            --title "$pr_title" \
            --body-file "$pr_body_file" \
            --draft)
        ok "Created PR: $new_url"
        warn "Add this URL to generate-branches.sh: LLM_PR=\"$new_url\""
    fi
}

push_branches() {
    local branches=("mig" "$LLM_BRANCH")
    for transform in "${TRANSFORMS[@]}"; do
        branches+=("$(tvar "$transform" "branch")")
    done

    # Filter out branches that don't exist locally (e.g., when --llm-only skipped leaves)
    local existing=()
    for b in "${branches[@]}"; do
        if git_bar rev-parse --verify "$b" >/dev/null 2>&1; then
            existing+=("$b")
        fi
    done

    step "Force-pushing: ${existing[*]} -> $REMOTE"
    git_bar push "$REMOTE" --force-with-lease "${existing[@]}"
    ok "Pushed to $REMOTE"
}

# ─── CLI ─────────────────────────────────────────────────────────────────────

DO_PUSH=false
DO_UPDATE_PRS=false
DO_LLM_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --push)       DO_PUSH=true; shift ;;
        --update-prs) DO_UPDATE_PRS=true; shift ;;
        --llm-only)   DO_LLM_ONLY=true; shift ;;
        -h|--help)
            echo "Usage: generate-branches.sh [--push] [--update-prs] [--llm-only]"
            echo ""
            echo "Reconstructs fmt, standalone leaf (mig-*), combined mig, and the"
            echo "fmt-llm capstone branch."
            echo ""
            echo "Flags:"
            echo "  --push        Force-push all branches to $REMOTE"
            echo "  --update-prs  Update all PR descriptions via gh (creates new PRs for leaves without one)"
            echo "  --llm-only    Skip leaves and mig rebuild; only rebuild fmt-llm from"
            echo "                existing mig (fast iteration on the LLM step)"
            exit 0
            ;;
        *)
            err "Unknown flag: $1"
            exit 1
            ;;
    esac
done

# ─── Run ─────────────────────────────────────────────────────────────────────

step "Fetching origin..."
git_bar fetch origin

if [[ "$DO_LLM_ONLY" == "true" ]]; then
    step "--llm-only: skipping leaves and mig rebuild"
    if ! git_bar rev-parse --verify mig >/dev/null 2>&1; then
        err "mig branch does not exist locally — run a full pipeline first"
        exit 1
    fi
    build_fmt_llm
else
    step "Rebasing prefix and prereq branches onto origin/master..."
    for prefix in "${PREFIX_BRANCHES[@]}"; do
        step "  Rebasing $prefix..."
        git_bar checkout --force "$prefix"
        git_bar rebase origin/master
    done
    for transform in "${TRANSFORMS[@]}"; do
        prereq=$(tvar "$transform" "prereq")
        if [[ -n "$prereq" ]]; then
            step "  Rebasing $prereq..."
            git_bar checkout --force "$prereq"
            git_bar rebase origin/master
        fi
    done

    for transform in "${TRANSFORMS[@]}"; do
        build_leaf "$transform"
    done

    build_mig
    build_fmt_llm
fi

generate_all_pr_bodies

if [[ "$DO_PUSH" == "true" ]] || [[ "$DO_UPDATE_PRS" == "true" ]]; then
    push_branches
fi

if [[ "$DO_UPDATE_PRS" == "true" ]]; then
    update_prs
fi

echo ""
ok "All branches rebuilt."
if [[ "$DO_LLM_ONLY" == "true" ]]; then
    info "  $LLM_BRANCH"
else
    leaf_names=""
    for transform in "${TRANSFORMS[@]}"; do
        leaf_names+="$(tvar "$transform" "branch"), "
    done
    info "  ${leaf_names}mig, $LLM_BRANCH"
fi
