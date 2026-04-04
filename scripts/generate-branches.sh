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

build_leaf() {
    local transform="$1"
    local branch commit_msg prereq
    branch=$(tvar "$transform" "branch")
    commit_msg=$(tvar "$transform" "commit")
    prereq=$(tvar "$transform" "prereq")

    step "Building leaf: $branch"
    git_bar checkout --force -B "$branch" origin/master

    if [[ -n "$prereq" ]]; then
        step "Cherry-picking prereq commits from $prereq..."
        git_bar cherry-pick origin/master.."$prereq"
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

    local -A mig_prereqs_picked
    for transform in "${TRANSFORMS[@]}"; do
        local prereq
        prereq=$(tvar "$transform" "prereq")
        if [[ -n "$prereq" ]] && [[ -z "${mig_prereqs_picked["$prereq"]:-}" ]]; then
            step "Cherry-picking prereq commits from $prereq..."
            git_bar cherry-pick origin/master.."$prereq"
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

# ─── PR body + update phase (runs after all branches exist) ──────────────────

generate_all_pr_bodies() {
    step "Generating PR bodies (with diff stats)..."

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
}

update_prs() {
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
}

push_branches() {
    local branches=("mig")
    for transform in "${TRANSFORMS[@]}"; do
        branches+=("$(tvar "$transform" "branch")")
    done

    step "Force-pushing: ${branches[*]} -> $REMOTE"
    git_bar push "$REMOTE" --force-with-lease "${branches[@]}"
    ok "All branches pushed to $REMOTE"
}

# ─── CLI ─────────────────────────────────────────────────────────────────────

DO_PUSH=false
DO_UPDATE_PRS=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --push)       DO_PUSH=true; shift ;;
        --update-prs) DO_UPDATE_PRS=true; shift ;;
        -h|--help)
            echo "Usage: generate-branches.sh [--push] [--update-prs]"
            echo ""
            echo "Reconstructs fmt, standalone leaf (mig-*), and combined mig branches."
            echo ""
            echo "Flags:"
            echo "  --push        Force-push all branches to $REMOTE"
            echo "  --update-prs  Update all PR descriptions via gh (creates new PRs for leaves without one)"
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

step "Rebasing prereq branches onto origin/master..."
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

generate_all_pr_bodies

if [[ "$DO_PUSH" == "true" ]] || [[ "$DO_UPDATE_PRS" == "true" ]]; then
    push_branches
fi

if [[ "$DO_UPDATE_PRS" == "true" ]]; then
    update_prs
fi

echo ""
ok "All branches rebuilt."
leaf_names=""
for transform in "${TRANSFORMS[@]}"; do
    leaf_names+="$(tvar "$transform" "branch"), "
done
info "  ${leaf_names}mig"
