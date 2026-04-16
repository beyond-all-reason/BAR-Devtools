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

# Tracking issue that ties all of the type-cleanup PRs together. Each leaf,
# the mig rollup, and the LLM capstone link to it as "Part of <issue>" so
# the PR bodies stay focused on their own step.
TRACKING_ISSUE="https://github.com/beyond-all-reason/Beyond-All-Reason/issues/7408"

# Tooling PR — the BAR-Devtools side that ships generate-branches.sh,
# llm-type-triage.sh, the codemod transforms, SKILL.md, and the just recipes.
DEVTOOLS_PR="https://github.com/beyond-all-reason/BAR-Devtools/pull/17"

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
LLM_SOURCE_PR=""
LLM_SOURCE_PR_TITLE="[Types] LLM env layer (emmylua config, type stubs, manual fixes)"
LLM_BRANCH="fmt-llm"
LLM_COMMIT_PREFIX="gen(llm): type-error triage"
LLM_PR="https://github.com/beyond-all-reason/Beyond-All-Reason/pull/7407"
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

TRANSFORMS=("fmt" "bracket_to_dot" "rename_aliases" "detach_bar_modules" "i18n_kikito" "spring_split" "integration_tests" "busted_types")

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
    # .git-blame-ignore-revs is no longer written here. It's deferred to the
    # final fmt-llm rollup (commit_blame_ignore_revs) so the file doesn't
    # conflict when the LLM env commits are replayed onto fresh mig builds
    # with different transform SHAs.
    :
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

# -- integration-tests ---------------------------------------------------------
# Carried-commit leaf (not a codemod). The curated branch contains a single
# hand-authored commit that restructures the integration tests under
# luaui/Tests and luaui/TestsExamples from bare-global hook declarations to
# a return-table shape, plus patches dbg_test_runner.lua to read hooks from
# the returned table. run_*() is a no-op — build_leaf's prereq cherry-pick
# brings the content in, and the trailing git commit is skipped because the
# working tree has no additional changes (see build_leaf guard).

integration_tests_branch="mig-integration-tests"
integration_tests_commit="gen(hand): integration tests return-table shape"
integration_tests_pr="https://github.com/beyond-all-reason/Beyond-All-Reason/pull/7437"
integration_tests_pr_title="[Tests] Restructure integration tests to table-return shape"
integration_tests_prereq="integration-tests-curated"
integration_tests_description='Carried-commit leaf. Restructures `luaui/Tests/` and `luaui/TestsExamples/` (20 files) from bare-global hook declarations to a `return { ... }` shape, and patches `dbg_test_runner.lua` to read hooks from the returned table. Isolated so the convention change can be discussed/reverted independently.'

run_integration_tests() {
    : # carried-commit leaf; prereq cherry-pick is the entire payload
}

describe_integration_tests() {
    cat <<'EOF'
# integration-tests - restructure luaui/Tests and luaui/TestsExamples files
# from bare-global hook declarations to a return-table shape; patch the
# dbg_test_runner widget to read hooks from the returned table. Carried-
# commit leaf — no codemod; curated branch holds the hand-authored commit.
EOF
}

# -- busted-types --------------------------------------------------------------
# Carried-commit leaf (not a codemod). The curated branch contains a single
# hand-authored commit that vendors LuaCATS busted + luassert type annotations
# under types/busted and types/luassert with per-directory provenance.md. Same
# no-op pattern as integration_tests.

busted_types_branch="mig-busted-types"
busted_types_commit="gen(hand): inline luassert and busted LuaCATS types"
busted_types_pr="https://github.com/beyond-all-reason/Beyond-All-Reason/pull/7438"
busted_types_pr_title="[Types] Inline LuaCATS busted+luassert type annotations"
busted_types_prereq="busted-types-curated"
busted_types_description='Carried-commit leaf. Vendors [LuaCATS/busted](https://github.com/LuaCATS/busted) and [LuaCATS/luassert](https://github.com/LuaCATS/luassert) type annotations under `types/busted/` and `types/luassert/`. Waits on [lumen-oss/lux#953](https://github.com/lumen-oss/lux/issues/953) to replace with a Lux dev-dep declaration.'

run_busted_types() {
    : # carried-commit leaf; prereq cherry-pick is the entire payload
}

describe_busted_types() {
    cat <<'EOF'
# busted-types - vendor LuaCATS busted + luassert type annotations under
# types/busted and types/luassert with per-directory provenance.md. Carried-
# commit leaf — no codemod; curated branch holds the hand-authored commit.
EOF
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

tvar() { eval echo "\${${1}_${2}:-}"; }

declare -A TEST_RESULTS

# Path inside BAR's .git/ where the most recent run's test results are
# cached. --skip-generation reads this so PR-body topology tables can show
# the last known unit-test status instead of "n/a" everywhere.
TEST_RESULTS_CACHE="$BAR/.git/test-results.cache"

persist_test_results() {
    : > "$TEST_RESULTS_CACHE"
    for branch in "${!TEST_RESULTS[@]}"; do
        printf '%s\t%s\n' "$branch" "${TEST_RESULTS[$branch]}" >> "$TEST_RESULTS_CACHE"
    done
}

load_test_results() {
    if [[ ! -f "$TEST_RESULTS_CACHE" ]]; then
        return 1
    fi
    local branch status
    while IFS=$'\t' read -r branch status; do
        [[ -n "$branch" ]] && TEST_RESULTS["$branch"]="$status"
    done < "$TEST_RESULTS_CACHE"
}

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
    # Bail with a clear marker if either ref is missing locally — happens in
    # --llm-only mode when the leaves were skipped, or before a full pipeline
    # has ever run.
    if ! git_bar rev-parse --verify "$1" >/dev/null 2>&1; then
        echo "(base $1 not present locally)"
        return
    fi
    if ! git_bar rev-parse --verify "$2" >/dev/null 2>&1; then
        echo "(branch not built locally)"
        return
    fi
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

# ─── Museum table (linear commit walk for rollup PR bodies) ──────────────────
#
# Rollup branches (`mig`, `fmt-llm`) carry many commits each from different
# layers. The museum table renders one row per commit, in order, with a
# clickable hash linking to the commit on the fork (FORK_OWNER). Reviewers
# walk the stack like exhibits — descriptions are intentionally one-line so
# the table is scannable; the umbrella issue carries the rationale.

museum_description() {
    local subject="$1"
    case "$subject" in
        "gen(stylua):"*)
            echo "stylua across the entire codebase" ;;
        "gen(bar_codemod): bracket-to-dot")
            echo 'x["y"] → x.y, ["y"]= → y= via full_moon AST rewrite' ;;
        "gen(bar_codemod): rename-aliases")
            echo "deprecated Spring API aliases (GetMyTeamID → GetLocalTeamID, etc.)" ;;
        "gen(bar_codemod): detach-bar-modules")
            echo "Spring.{I18N,Utilities,Debug,Lava,GetModOptionsCopy} → bare globals" ;;
        "gen(bar_codemod): spring-split")
            echo "Spring.X → SpringSynced/SpringUnsynced/SpringShared.X per @context" ;;
        "gen(bar_codemod): i18n-kikito")
            echo "vendored gajop/i18n → kikito/i18n.lua via lux dependency" ;;
        "gen(hand): integration tests return-table shape")
            echo "luaui/Tests + luaui/TestsExamples → return-table shape; dbg_test_runner reads hooks from the returned table" ;;
        "gen(hand): inline luassert and busted LuaCATS types")
            echo "vendored LuaCATS/busted + LuaCATS/luassert type annotations under types/ (pending lumen-oss/lux#953)" ;;
        "git-blame-ignore-revs:"*)
            echo "register transform commits with git blame" ;;
        "env(llm):"*)
            echo ".emmyrc.json globals, types/* stubs, busted mock, CI gate, manual fixes" ;;
        "gen(llm):"*)
            echo "parallel LLM workers applying SKILL.md fix recipes per file chunk" ;;
        "env:"*)
            # Self-describing prereq commits — strip the prefix.
            echo "${subject#env: }" ;;
        "deps:"*)
            echo "${subject#deps: }" ;;
        *)
            echo "—" ;;
    esac
}

# Render a markdown table of every commit unique to <branch> vs origin/master,
# in the order they were applied. Hashes link to the fork (where the branches
# actually live) so reviewers can click through any individual commit.
generate_museum_table() {
    local branch="$1"
    local pr_url="$2"

    echo "### Commits"
    echo ""
    echo "| # | Commit | What it does |"
    echo "|---|--------|--------------|"

    local i=1
    while IFS=$'\t' read -r short long subject; do
        local desc commit_url
        desc="$(museum_description "$subject")"
        if [[ -n "$pr_url" ]]; then
            commit_url="${pr_url}/commits/${long}"
        else
            commit_url="https://github.com/${FORK_OWNER}/Beyond-All-Reason/commit/${long}"
        fi
        echo "| $i | [\`${short}\`](${commit_url}) \`${subject}\` | ${desc} |"
        i=$((i + 1))
    done < <(git_bar log --reverse --format='%h	%H	%s' "origin/master..$branch")
}

generate_topology() {
    echo "### Branch Topology"
    echo ""
    echo "All branches in the [BAR type-error cleanup]($TRACKING_ISSUE) stack. Regenerated deterministically by [\`just bar::fmt-mig-generate\`]($DEVTOOLS_PR). *Generated $(date -u +"%Y-%m-%d %H:%M:%S UTC").*"
    echo ""
    echo "**Leaves** — each targets \`master\`, mergeable independently:"
    echo ""
    echo "| Branch | Command | Diff vs \`master\` | Units |"
    echo "|--------|---------|------|-------|"
    for transform in "${TRANSFORMS[@]}"; do
        local branch pr_url stats command
        branch=$(tvar "$transform" "branch")
        pr_url=$(tvar "$transform" "pr")
        stats=$(diff_stat origin/master "$branch")
        # Most transforms invoke `bar-lua-codemod <name>`. Exceptions are
        # hand-maintained:
        #   - fmt: runs stylua, not the codemod
        #   - carried-commit leaves (integration_tests, busted_types): content
        #     comes from a curated prereq branch; no codemod or automation
        case "$transform" in
            fmt)
                command="\`stylua\`" ;;
            integration_tests|busted_types)
                command="\`<hand curated>\`" ;;
            *)
                command="\`bar-lua-codemod ${transform//_/-}\`" ;;
        esac
        echo "| $(pr_link "$branch" "$pr_url") | $command | $stats | $(unit_status "$branch") |"
    done
    echo ""
    echo "**Rollups** — composite branches stacking the leaves and (for \`fmt-llm\`) the env + LLM layers:"
    echo ""
    echo "| Branch | Diff vs \`master\` | Diff vs \`mig\` | Units |"
    echo "|--------|------|------|-------|"
    echo "| $(pr_link "mig" "$MIG_PR") | $(diff_stat origin/master mig) | — | $(unit_status mig) |"
    echo "| $(pr_link "$LLM_SOURCE_BRANCH" "$LLM_SOURCE_PR") | $(diff_stat origin/master "$LLM_SOURCE_BRANCH") | $(diff_stat mig "$LLM_SOURCE_BRANCH") | $(unit_status "$LLM_SOURCE_BRANCH") |"
    echo "| $(pr_link "$LLM_BRANCH" "$LLM_PR") | $(diff_stat origin/master "$LLM_BRANCH") | $(diff_stat mig "$LLM_BRANCH") | $(unit_status "$LLM_BRANCH") |"
}

generate_leaf_pr_body() {
    local transform="$1" output_file="$2"
    local description
    description=$(tvar "$transform" "description")

    echo "Part of [BAR type-error cleanup]($TRACKING_ISSUE). Rebuilds idempotently from \`master\` via [\`just bar::fmt-mig-generate\`]($DEVTOOLS_PR)."
    echo ""
    echo '```sh'
    "describe_${transform}"
    echo '```'
    if [[ -n "$description" ]]; then
        echo ""
        echo "$description"
    fi
    echo ""
    generate_topology
}

generate_mig_pr_body() {
    local _output_file="$1"  # unused; output bundle was previously inlined here

    echo "Part of [BAR type-error cleanup]($TRACKING_ISSUE). Combined deterministic transforms — what \`master\` looks like with every leaf applied sequentially."
    echo ""
    generate_museum_table mig "$MIG_PR"
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
    abort_stuck_git_state
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
    # Carried-commit leaves (e.g. integration_tests, busted_types) have a
    # no-op run_*() and rely entirely on the prereq cherry-pick for content.
    # Skip the trailing commit in that case — the prereq commit's message
    # stands as the leaf tip and "nothing to commit" would abort the script.
    if git_bar diff --cached --quiet; then
        info "  (skip) run_${transform} produced no changes — prereq commit stands as $branch tip"
    else
        git_bar commit -m "$commit_msg"
    fi

    if type "post_commit_${transform}" &>/dev/null; then
        "post_commit_${transform}"
    fi

    run_tests "$branch"

    ok "Leaf $branch ready"
}

build_mig() {
    step "Building linear mig branch..."
    abort_stuck_git_state
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
        # Carried-commit leaves contributed their content via the prereq
        # cherry-pick earlier (and stylua left it alone). Skip an empty
        # commit here — otherwise git aborts build_mig on "nothing to commit"
        # and the transform hash recorded below would be stale.
        if git_bar diff --cached --quiet; then
            info "  (skip) mig: $transform produced no changes — prereq commit already in mig"
        else
            git_bar commit -m "$commit_msg"
        fi
        transform_hashes+=("$(git_bar rev-parse HEAD)")
    done

    # Cache transform hashes for the final blame-ignore commit on fmt-llm.
    # Committing the file here would conflict when fmt-llm-source env commits
    # are replayed onto new mig builds with different transform SHAs.
    local blame_cache="$BAR/.git/mig-blame-hashes.txt"
    : > "$blame_cache"
    for i in "${!TRANSFORMS[@]}"; do
        local transform="${TRANSFORMS[$i]}"
        local commit_msg
        commit_msg=$(tvar "$transform" "commit")
        printf '%s\t%s\n' "${transform_hashes[$i]}" "$commit_msg" >> "$blame_cache"
    done

    run_tests "mig"

    ok "mig branch ready (${#TRANSFORMS[@]} commits)"
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
#   1. Auto-detecting the env anchor on $LLM_SOURCE_BRANCH (walk from tip down,
#      first commit whose subject does NOT start with `env(llm):` is the anchor;
#      everything above it is env content, replayed onto current mig).
#   2. Cherry-picking only those env commits onto a fresh fmt-llm off mig.
#   3. Running the LLM type-triage fan-out (drives just bar::check errors → 0).
#   4. Committing whatever the workers edited as one gen(llm) commit.
#
# The source branch is user-maintained, like detach-bar-modules-env / lux-i18n.
# Bootstrap: just author env(llm): commits on top of some existing mig-ish
# base. The only shape requirement is that env commits live contiguously at
# the tip of $LLM_SOURCE_BRANCH with subjects prefixed `env(llm):`.
#
# Subsequent env edits: check out $LLM_SOURCE_BRANCH, amend or add more
# env(llm): commits on top. Mig drift below the anchor is automatically
# ignored — the replay range is computed from subjects each run, not stored.
build_fmt_llm() {
    abort_stuck_git_state

    if ! git_bar rev-parse --verify "$LLM_SOURCE_BRANCH" >/dev/null 2>&1; then
        err "LLM source branch '$LLM_SOURCE_BRANCH' not found in BAR repo"
        err ""
        err "Bootstrap it by authoring env commits on top of mig:"
        err "  git -C $BAR checkout -b $LLM_SOURCE_BRANCH mig"
        err "  # ...edit .emmyrc.json, types/*, etc..."
        err "  git -C $BAR commit -am 'env(llm): emmylua config + type stubs'"
        err ""
        err "Env commits must have subjects prefixed 'env(llm):' and live"
        err "contiguously at the branch tip. The replay anchor is auto-detected"
        err "as the first non-env(llm): commit walking down from the tip."
        exit 1
    fi

    local new_mig_sha env_anchor env_commit_count
    new_mig_sha=$(git_bar rev-parse mig)

    # Walk $LLM_SOURCE_BRANCH from tip downward; stop at the first commit whose
    # subject is NOT `env(llm): ...`. That commit is the anchor. Pure-shell
    # implementation (no awk) so the script works in minimal distroboxes.
    env_anchor=""
    while IFS=$'\t' read -r sha subject; do
        case "$subject" in
            "env(llm):"*) continue ;;
            *) env_anchor="$sha"; break ;;
        esac
    done < <(git_bar log --format='%H%x09%s' "$LLM_SOURCE_BRANCH")

    if [[ -z "$env_anchor" ]]; then
        err "Could not detect an env anchor on $LLM_SOURCE_BRANCH — no commit"
        err "with a non-'env(llm):' subject was found walking from the tip."
        err "Is $LLM_SOURCE_BRANCH rooted at origin/master (or a mig variant)?"
        exit 1
    fi

    env_commit_count=$(git_bar rev-list --count "$env_anchor..$LLM_SOURCE_BRANCH")
    step "Cherry-picking $env_commit_count env commit(s) from $LLM_SOURCE_BRANCH onto mig..."
    step "  env anchor: $env_anchor ($(git_bar log -1 --format=%s "$env_anchor"))"
    step "  new mig:    $new_mig_sha"

    # Build fmt-llm fresh from mig, then cherry-pick the env commits on top.
    # fmt-llm-source itself is NOT mutated — same fail-fast philosophy as the
    # prereq rebase guard: if cherry-pick conflicts, a transform on mig has
    # diverged from what the env commit expects. The maintainer rebuilds
    # fmt-llm-source by hand rather than silently merging unrelated changes.
    # (See the lux-i18n bloat incident for why in-place rebase/merge was bad.)
    git_bar checkout --force -B "$LLM_BRANCH" mig

    if [[ "$env_commit_count" == "0" ]]; then
        warn "$LLM_SOURCE_BRANCH has no env commits above the anchor — env layer is empty"
    else
        if ! git_bar cherry-pick "$env_anchor..$LLM_SOURCE_BRANCH"; then
            local conflicted
            conflicted=$(git_bar diff --name-only --diff-filter=U | sed 's/^/    /')
            err ""
            err "Cherry-pick conflict replaying $LLM_SOURCE_BRANCH env commits onto mig."
            err "A transform on mig modified file(s) also touched by an env commit:"
            err ""
            err "$conflicted"
            err ""
            err "Option 1 — resolve and continue (stays on $LLM_BRANCH):"
            err "  cd $BAR"
            err "  # ...edit conflicted files, pick the right side..."
            err "  git add -A && git cherry-pick --continue"
            err "  git checkout $LLM_SOURCE_BRANCH && git cherry-pick $LLM_BRANCH~..$LLM_BRANCH  # propagate the fix"
            err "  cd $DEVTOOLS_DIR && just bar::fmt-mig-generate --llm-only"
            err ""
            err "Option 2 — abort and rebuild $LLM_SOURCE_BRANCH from scratch (safer, avoids"
            err "pulling unrelated upstream changes into the env commit — see the lux-i18n"
            err "bloat incident):"
            err "  cd $BAR && git cherry-pick --abort"
            err "  git checkout $LLM_SOURCE_BRANCH && git reset --hard mig"
            err "  # ...re-apply env edits..."
            err "  git commit -am 'env(llm): emmylua config + type stubs'"
            err "  cd $DEVTOOLS_DIR && just bar::fmt-mig-generate --llm-only"
            exit 1
        fi
    fi

    # ── LLM layer: run the triage fan-out and commit its edits ──
    local before
    before=$(emmylua_error_count)
    step "$LLM_BRANCH pre-triage errors: $before"

    if [[ "$before" == "0" ]]; then
        ok "$LLM_BRANCH already at zero errors — skipping triage"
    else
        # Run inside the same container we already entered. NO host_exec —
        # routing through distrobox-host-exec would drop env vars
        # (DEVTOOLS_DISTROBOX, _DEVTOOLS_IN_DISTROBOX) and PATH adjustments.
        bash "${DEVTOOLS_DIR}/scripts/codemod/llm-type-triage.sh"
    fi

    # LLM workers don't run stylua — reformat whatever they touched so the
    # gen(llm) commit is stylua-clean and doesn't introduce formatting drift.
    stylua_pass

    local after
    after=$(emmylua_error_count)
    step "$LLM_BRANCH post-triage errors: $after"

    git_bar add -A
    if git_bar diff --cached --quiet; then
        warn "LLM triage produced no edits — skipping LLM commit"
    else
        git_bar commit -m "$LLM_COMMIT_PREFIX ($before → $after errors)

Generated by parallel claude-sonnet-4-6 workers dispatched by
scripts/codemod/llm-type-triage.sh, applying fixes per SKILL.md categories.
Single pass, no iteration — categories that don't shrink the count
are a signal that SKILL.md needs a new rule."
    fi

    commit_blame_ignore_revs

    run_tests "$LLM_BRANCH"

    ok "$LLM_BRANCH ready"
}

# Writes .git-blame-ignore-revs with every transform commit SHA (cached by
# build_mig) and commits it on the current branch. Deferred to fmt-llm so the
# file never conflicts during env-commit cherry-picks onto fresh mig builds.
commit_blame_ignore_revs() {
    local blame_cache="$BAR/.git/mig-blame-hashes.txt"
    if [[ ! -f "$blame_cache" ]]; then
        warn "No cached transform hashes at $blame_cache — skipping blame-ignore-revs"
        return
    fi

    step "Committing .git-blame-ignore-revs on $LLM_BRANCH..."
    : > "$BAR/.git-blame-ignore-revs"
    while IFS=$'\t' read -r sha msg; do
        [[ -z "$sha" ]] && continue
        printf '# %s\n%s\n\n' "$msg" "$sha" >> "$BAR/.git-blame-ignore-revs"
    done < "$blame_cache"
    git_bar add .git-blame-ignore-revs
    git_bar commit -m "git-blame-ignore-revs: add transform commits"
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

    # fmt-llm-source env layer PR body.
    if git_bar rev-parse --verify "$LLM_SOURCE_BRANCH" >/dev/null 2>&1; then
        pr_body_file="$BAR/.git/${LLM_SOURCE_BRANCH}-pr-body.md"
        generate_llm_source_pr_body > "$pr_body_file"
        ok "  $LLM_SOURCE_BRANCH PR body: $pr_body_file"
    fi

    # LLM capstone PR body (only generated when fmt-llm exists).
    if git_bar rev-parse --verify "$LLM_BRANCH" >/dev/null 2>&1; then
        pr_body_file="$BAR/.git/${LLM_BRANCH}-pr-body.md"
        generate_llm_pr_body > "$pr_body_file"
        ok "  $LLM_BRANCH PR body: $pr_body_file"

        # Tracking issue body (depends on fmt-llm for the museum table).
        local tracking_body_file="$BAR/.git/tracking-issue-body.md"
        generate_tracking_issue_body > "$tracking_body_file"
        ok "  tracking issue body: $tracking_body_file"
    fi
}

generate_llm_source_pr_body() {
    echo "Part of [BAR type-error cleanup]($TRACKING_ISSUE). Human-curated env layer that prepares the codebase for the LLM type-fix pass."
    echo ""
    echo "This branch carries:"
    echo "- \`.emmyrc.json\` globals and analyzer config"
    echo "- \`types/*\` stubs for vendored/generated declarations"
    echo "- CI gate configuration"
    echo "- Manual source fixes that require human judgement"
    echo ""
    echo "Maintained independently — rebased onto \`mig\` each pipeline run. The [fmt-llm capstone]($LLM_PR) cherry-picks these commits then runs the LLM triage on top."
    echo ""
    generate_museum_table "$LLM_SOURCE_BRANCH" "$LLM_SOURCE_PR"
    echo ""
    generate_topology
}

generate_llm_pr_body() {
    local summary_file
    summary_file="$BAR/.git/llm-triage-summary.txt"

    echo "Part of [BAR type-error cleanup]($TRACKING_ISSUE). Final stage: deterministic transforms + env layer + LLM type-fix pass."
    echo ""
    generate_museum_table "$LLM_BRANCH" "$LLM_PR"
    echo ""
    if [[ -f "$summary_file" ]]; then
        echo '### Triage run'
        echo ''
        echo '```'
        cat "$summary_file"
        echo '```'
        echo ''
    fi
    generate_topology
}

# Simpler variant of generate_topology for the tracking issue — drops the
# diff-stat + unit-status columns and the timestamp/regen-link preamble. Uses
# current *_pr URLs so the template picks up newly-created PRs on re-run.
generate_issue_branch_topology() {
    local leaf_count=${#TRANSFORMS[@]}
    echo "<details>"
    echo "<summary>Branch topology (${leaf_count} leaves + 2 rollups)</summary>"
    echo ""
    echo "### Leaves — each targets \`master\`, mergeable independently"
    echo ""
    echo "| Branch | Command | What it does |"
    echo "|--------|---------|--------------|"
    for transform in "${TRANSFORMS[@]}"; do
        local branch pr_url command desc
        branch=$(tvar "$transform" "branch")
        pr_url=$(tvar "$transform" "pr")
        case "$transform" in
            fmt)
                command="\`stylua\`" ;;
            integration_tests|busted_types)
                command="\`<hand curated>\`" ;;
            *)
                command="\`bar-lua-codemod ${transform//_/-}\`" ;;
        esac
        desc=$(museum_description "$(tvar "$transform" "commit")")
        echo "| $(pr_link "$branch" "$pr_url") | $command | $desc |"
    done
    echo ""
    echo "### Rollups — composite branches stacking the leaves and (for \`fmt-llm\`) the env + LLM layers"
    echo ""
    echo "| Branch | Notes |"
    echo "|--------|-------|"
    echo "| $(pr_link "mig" "$MIG_PR") | all leaves combined; deterministic rebuild from \`master\` |"
    echo "| $(pr_link "$LLM_SOURCE_BRANCH" "$LLM_SOURCE_PR") | \`mig\` + human-curated env layer (\`.emmyrc.json\`, \`types/*\` stubs, CI gate, manual fixes) |"
    echo "| $(pr_link "$LLM_BRANCH" "$LLM_PR") | \`$LLM_SOURCE_BRANCH\` + one LLM triage commit |"
    echo ""
    echo "Regenerated deterministically by [\`just bar::fmt-mig-generate\`]($DEVTOOLS_PR)."
    echo ""
    echo "</details>"
}

generate_tracking_issue_body() {
    local template="${DEVTOOLS_DIR}/scripts/codemod/tracking-issue-template.md"
    if [[ ! -f "$template" ]]; then
        warn "Tracking issue template not found: $template"
        return 1
    fi

    local museum_table commit_count
    museum_table=$(generate_museum_table "$LLM_BRANCH" "$LLM_PR")
    commit_count=$(git_bar rev-list --count "origin/master..$LLM_BRANCH")

    local museum_replacement
    museum_replacement=$(cat <<EOF
<details>
<summary>Commit-by-commit breakdown (${commit_count} commits)</summary>

${museum_table}

</details>
EOF
    )

    local topology_replacement
    topology_replacement=$(generate_issue_branch_topology)

    # Replace each token with its generated block. awk because sed chokes on
    # multi-line replacements with pipes/backticks.
    awk \
        -v museum_token="<!-- GENERATED:MUSEUM_TABLE -->" \
        -v museum_replacement="$museum_replacement" \
        -v topology_token="<!-- GENERATED:BRANCH_TOPOLOGY -->" \
        -v topology_replacement="$topology_replacement" \
        '{
            if ($0 == museum_token) print museum_replacement
            else if ($0 == topology_token) print topology_replacement
            else print
        }' \
        "$template"
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

    # fmt-llm-source env layer PR.
    update_capstone_pr "$LLM_SOURCE_BRANCH" "$LLM_SOURCE_PR" "$LLM_SOURCE_PR_TITLE"

    # fmt-llm capstone PR (only one branch — env layer is folded into it).
    update_capstone_pr "$LLM_BRANCH" "$LLM_PR" "$LLM_PR_TITLE"

    # Tracking issue — update the body with the latest museum table.
    local tracking_body_file="$BAR/.git/tracking-issue-body.md"
    if [[ -f "$tracking_body_file" ]] && [[ -n "$TRACKING_ISSUE" ]]; then
        step "Updating tracking issue $TRACKING_ISSUE..."
        gh_host issue edit "$TRACKING_ISSUE" --body-file "$tracking_body_file"
        ok "Tracking issue updated"
    fi
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

    # fmt-llm targets master because `mig` is local-only — never pushed as a
    # base branch on origin. The PR body explains the layer structure
    # (master → mig → env → LLM) so reviewers can read the diff in stages.
    local base="master"

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
    local branches=("mig" "$LLM_SOURCE_BRANCH" "$LLM_BRANCH")
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
DO_SKIP_GENERATION=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --push)             DO_PUSH=true; shift ;;
        --update-prs)       DO_UPDATE_PRS=true; shift ;;
        --llm-only)         DO_LLM_ONLY=true; shift ;;
        --skip-generation)  DO_SKIP_GENERATION=true; shift ;;
        -h|--help)
            cat <<HELP
Usage: generate-branches.sh [--push] [--update-prs] [--llm-only|--skip-generation]

Reconstructs fmt, standalone leaf (mig-*), combined mig, and the
fmt-llm capstone branch.

Flags:
  --push              Force-push all branches to $REMOTE
  --update-prs        Update all PR descriptions via gh (creates new PRs
                      for leaves without one)
  --llm-only          Skip leaves and mig rebuild; only rebuild fmt-llm
                      from existing mig (fast iteration on the LLM step)
  --skip-generation   Skip ALL branch rebuilds — no leaves, no mig, no
                      fmt-llm. Just regenerate PR bodies (and push/update
                      PRs if --push/--update-prs is also passed) against
                      the existing local branches. Use after editing
                      generate-branches.sh constants like PR URLs or
                      museum descriptions.
HELP
            exit 0
            ;;
        *)
            err "Unknown flag: $1"
            exit 1
            ;;
    esac
done

if [[ "$DO_LLM_ONLY" == "true" ]] && [[ "$DO_SKIP_GENERATION" == "true" ]]; then
    err "--llm-only and --skip-generation are mutually exclusive"
    exit 1
fi

# ─── Run ─────────────────────────────────────────────────────────────────────

step "Fetching origin..."
git_bar fetch origin

if [[ "$DO_SKIP_GENERATION" == "true" ]]; then
    step "--skip-generation: skipping ALL branch rebuilds (PR bodies only)"
    # Sanity check: at minimum the LLM capstone has to exist locally for
    # generate_all_pr_bodies to find anything to render. If even fmt-llm is
    # missing, the user is clearly trying to use this flag too aggressively.
    if ! git_bar rev-parse --verify "$LLM_BRANCH" >/dev/null 2>&1; then
        err "$LLM_BRANCH does not exist locally — run a full pipeline first"
        exit 1
    fi
    if load_test_results; then
        info "Loaded cached test results from $TEST_RESULTS_CACHE"
    else
        warn "No cached test results — topology tables will show 'n/a' for Units"
    fi
elif [[ "$DO_LLM_ONLY" == "true" ]]; then
    step "--llm-only: skipping leaves and mig rebuild"
    if ! git_bar rev-parse --verify mig >/dev/null 2>&1; then
        err "mig branch does not exist locally — run a full pipeline first"
        exit 1
    fi
    # Preserve leaf test results from a previous full run so the topology
    # tables aren't lying about untested branches.
    load_test_results || true
    build_fmt_llm
    persist_test_results
else
    step "Rebasing prefix and prereq branches onto origin/master..."
    # Prereq/prefix branches are small, hand-maintained (lux-i18n,
    # detach-bar-modules-env). A merge conflict means upstream changes have
    # diverged from the branch's assumptions — silently resolving via `-X
    # theirs` or accepting auto-merge has historically produced bloated
    # commits that pulled in unrelated upstream changes. Fail fast so the
    # maintainer can rebuild the branch by hand from origin/master.
    rebase_or_fail() {
        local branch="$1"
        if ! git_bar rebase origin/master; then
            git_bar rebase --abort 2>/dev/null || true
            err "Conflict rebasing $branch onto origin/master."
            err "Resolve by rebuilding the branch manually from origin/master:"
            err "  git checkout $branch && git reset --hard origin/master"
            err "  (cherry-pick or re-apply the intended commit, then re-run)"
            err "Refusing to continue to avoid polluting $branch with unrelated"
            err "upstream changes (see lux-i18n bloat incident)."
            exit 1
        fi
    }
    for prefix in "${PREFIX_BRANCHES[@]}"; do
        step "  Rebasing $prefix..."
        git_bar checkout --force "$prefix"
        rebase_or_fail "$prefix"
    done
    for transform in "${TRANSFORMS[@]}"; do
        prereq=$(tvar "$transform" "prereq")
        if [[ -n "$prereq" ]]; then
            step "  Rebasing $prereq..."
            git_bar checkout --force "$prereq"
            rebase_or_fail "$prereq"
        fi
    done

    for transform in "${TRANSFORMS[@]}"; do
        build_leaf "$transform"
    done

    build_mig
    build_fmt_llm
    persist_test_results
fi

generate_all_pr_bodies

if [[ "$DO_PUSH" == "true" ]] || [[ "$DO_UPDATE_PRS" == "true" ]]; then
    push_branches
fi

if [[ "$DO_UPDATE_PRS" == "true" ]]; then
    update_prs
fi

echo ""
if [[ "$DO_SKIP_GENERATION" == "true" ]]; then
    ok "PR bodies regenerated (no branches rebuilt)."
else
    ok "All branches rebuilt."
fi
if [[ "$DO_LLM_ONLY" == "true" ]] || [[ "$DO_SKIP_GENERATION" == "true" ]]; then
    info "  $LLM_BRANCH"
else
    leaf_names=""
    for transform in "${TRANSFORMS[@]}"; do
        leaf_names+="$(tvar "$transform" "branch"), "
    done
    info "  ${leaf_names}mig, $LLM_BRANCH"
fi
