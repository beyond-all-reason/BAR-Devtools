#!/usr/bin/env bash
# Repository management helpers.
# Expects: DEVTOOLS_DIR, REPOS_CONF, REPOS_LOCAL (exported by Justfile)
# Source scripts/common.sh before this file.

declare -a REPO_DIRS=() REPO_URLS=() REPO_BRANCHES=() REPO_FEATURES=() REPO_LOCAL_PATHS=()

load_repos_conf() {
  REPO_DIRS=(); REPO_URLS=(); REPO_BRANCHES=(); REPO_FEATURES=(); REPO_LOCAL_PATHS=()
  local -A seen=()
  local local_root="" protocol=""

  _parse_conf() {
    local file="$1"
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      line="$(echo "$line" | xargs 2>/dev/null || true)"
      [ -z "$line" ] && continue

      # Directive lines: @key value
      if [[ "$line" =~ ^@([a-z_]+)[[:space:]]+(.+)$ ]]; then
        local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
        case "$key" in
          local_root) local_root="${val/#\~/$HOME}" ;;
          protocol)   protocol="$val" ;;
          *)          warn "Unknown directive in $file: @$key" ;;
        esac
        continue
      fi

      local dir url branch feature local_path
      read -r dir url branch feature local_path <<< "$line"
      [ -z "$dir" ] && continue
      local_path="${local_path/#\~/$HOME}"

      # repos.local.conf is a per-field override: any column the user
      # leaves blank falls back to whatever repos.conf set. Only `dir`
      # is required (it's the join key); url/branch/feature/local_path
      # all merge. This means a local override only needs to list the
      # columns it actually wants to change -- typically just `url` for
      # a fork or `local_path` for a sibling checkout.
      local prev_url="" prev_branch="" prev_feature="" prev_local_path=""
      if [ -n "${seen[$dir]:-}" ]; then
        IFS='|' read -r prev_url prev_branch prev_feature prev_local_path <<< "${seen[$dir]}"
      fi
      url="${url:-$prev_url}"
      branch="${branch:-${prev_branch:-master}}"
      feature="${feature:-$prev_feature}"
      local_path="${local_path:-$prev_local_path}"
      [ -z "$url" ] && continue

      # Use a separator unlikely to appear in any field so the round-trip
      # through `read` survives empty feature/local_path columns.
      seen[$dir]="$url|$branch|$feature|$local_path"
    done < "$file"
  }

  _parse_conf "$REPOS_CONF"
  _parse_conf "$REPOS_LOCAL"

  local dir
  for dir in "${!seen[@]}"; do
    local url branch feature local_path
    IFS='|' read -r url branch feature local_path <<< "${seen[$dir]}"

    # @protocol: rewrite github.com URLs between https and ssh forms.
    if [ "$protocol" = "ssh" ] && [[ "$url" =~ ^https://github\.com/(.+)$ ]]; then
      url="git@github.com:${BASH_REMATCH[1]}"
    elif [ "$protocol" = "https" ] && [[ "$url" =~ ^git@github\.com:(.+)$ ]]; then
      url="https://github.com/${BASH_REMATCH[1]}"
    fi

    # @local_root: any repo without an explicit local_path gets $local_root/$dir.
    if [ -z "$local_path" ] && [ -n "$local_root" ]; then
      local_path="$local_root/$dir"
    fi

    REPO_DIRS+=("$dir")
    REPO_URLS+=("$url")
    REPO_BRANCHES+=("$branch")
    REPO_FEATURES+=("$feature")
    REPO_LOCAL_PATHS+=("$local_path")
  done
}

# True if comma-separated feature list $1 contains tag $2.
repo_has_feature() {
  local list="$1" tag="$2"
  local IFS=','
  local f
  for f in $list; do
    [ "$f" = "$tag" ] && return 0
  done
  return 1
}

clone_or_update_repo() {
  local dir="$1" url="$2" branch="$3" local_path="${4:-}" target="$DEVTOOLS_DIR/$dir"

  if [ -n "$local_path" ]; then
    if [ ! -d "$local_path" ]; then
      info "  ${dir}: local path absent; cloning ${url} into ${local_path}..."
      mkdir -p "$(dirname "$local_path")"
      if ! git clone --recurse-submodules --branch "$branch" "$url" "$local_path" 2>&1 | sed 's/^/    /'; then
        err "  ${dir}: clone into ${local_path} failed (check URL / SSH access)"
        return 1
      fi
    fi
    if [ -L "$target" ]; then
      local current_link
      current_link="$(readlink "$target")"
      if [ "$current_link" = "$local_path" ]; then
        ok "  ${dir}: linked -> ${local_path}"
      else
        warn "  ${dir}: symlink points to ${current_link}, config says ${local_path}"
        info "  ${dir}: updating symlink..."
        rm "$target"
        ln -s "$local_path" "$target"
        ok "  ${dir}: linked -> ${local_path}"
      fi
    elif [ -d "$target" ]; then
      warn "  ${dir}: exists as a real directory but config says link to ${local_path}"
      warn "  ${dir}: remove it manually to use the local path"
    else
      ln -s "$local_path" "$target"
      ok "  ${dir}: linked -> ${local_path}"
    fi
    return 0
  fi

  if [ -d "$target/.git" ]; then
    local current_url
    current_url="$(git -C "$target" remote get-url origin 2>/dev/null || true)"
    if [ "$current_url" != "$url" ] && [ -n "$current_url" ]; then
      warn "  ${dir}: origin is ${current_url}"
      warn "  ${dir}: config says ${url}"
      warn "  ${dir}: add to repos.local.conf to set your preferred remote"
    fi
    info "  ${dir}: fetching latest..."
    git -C "$target" fetch origin --quiet 2>/dev/null || warn "  ${dir}: fetch failed (offline?)"
    git -C "$target" submodule update --init --recursive --quiet 2>/dev/null \
      || warn "  ${dir}: submodule sync failed (offline or auth?)"
    local current_branch
    current_branch="$(git -C "$target" branch --show-current 2>/dev/null)"
    if [ -n "$current_branch" ] && [ "$current_branch" != "$branch" ]; then
      info "  ${dir}: on branch '${current_branch}' (config says '${branch}')"
    fi
  else
    info "  ${dir}: cloning ${url} (branch: ${branch})..."
    git clone --recurse-submodules --branch "$branch" "$url" "$target" 2>&1 | sed 's/^/    /'
  fi
}

cmd_clone() {
  local feature_filter="${1:-all}"
  load_repos_conf

  if [ "${#REPO_DIRS[@]}" -eq 0 ]; then
    err "No repositories found in repos.conf"
    exit 1
  fi

  echo -e "${BOLD}=== Cloning / Updating Repositories ===${NC}"
  echo ""

  if [ -f "$REPOS_LOCAL" ]; then
    info "Using overrides from repos.local.conf"
    echo ""
  fi

  local i cloned=0 updated=0 skipped=0 linked=0
  for i in "${!REPO_DIRS[@]}"; do
    local dir="${REPO_DIRS[$i]}"
    local url="${REPO_URLS[$i]}"
    local branch="${REPO_BRANCHES[$i]}"
    local feature="${REPO_FEATURES[$i]}"
    local local_path="${REPO_LOCAL_PATHS[$i]}"

    if [ "$feature_filter" != "all" ] && ! repo_has_feature "$feature" "$feature_filter"; then
      skipped=$((skipped + 1))
      continue
    fi

    if [ -n "$local_path" ]; then
      clone_or_update_repo "$dir" "$url" "$branch" "$local_path"
      linked=$((linked + 1))
    elif [ -d "$DEVTOOLS_DIR/$dir/.git" ]; then
      clone_or_update_repo "$dir" "$url" "$branch"
      updated=$((updated + 1))
    else
      clone_or_update_repo "$dir" "$url" "$branch"
      cloned=$((cloned + 1))
    fi
  done

  echo ""
  local summary="${cloned} cloned, ${updated} updated, ${skipped} skipped"
  [ "$linked" -gt 0 ] && summary+=", ${linked} linked"
  ok "Repos: ${summary}"
}

cmd_repos() {
  load_repos_conf

  echo -e "${BOLD}=== Repository Status ===${NC}"
  echo ""
  printf "  ${DIM}%-24s %-22s %-18s %s${NC}\n" "DIRECTORY" "FEATURE" "BRANCH" "STATUS"
  echo "  $(printf '%.0s-' {1..80})"

  local i
  for i in "${!REPO_DIRS[@]}"; do
    local dir="${REPO_DIRS[$i]}"
    local feature="${REPO_FEATURES[$i]:--}"
    local target="$DEVTOOLS_DIR/$dir"

    local status current_branch
    if [ -L "$target" ]; then
      local link_dest
      link_dest="$(readlink "$target")"
      if [ -d "$target/.git" ]; then
        current_branch="$(git -C "$target" branch --show-current 2>/dev/null || echo "detached")"
        local dirty=""
        if ! git -C "$target" diff --quiet 2>/dev/null || ! git -C "$target" diff --cached --quiet 2>/dev/null; then
          dirty=" ${YELLOW}*dirty*${NC}"
        fi
        status="${CYAN}local${NC}${dirty} -> ${link_dest}"
      else
        status="${RED}broken link${NC} -> ${link_dest}"
        current_branch="-"
      fi
    elif [ -d "$target/.git" ]; then
      current_branch="$(git -C "$target" branch --show-current 2>/dev/null || echo "detached")"
      local dirty=""
      if ! git -C "$target" diff --quiet 2>/dev/null || ! git -C "$target" diff --cached --quiet 2>/dev/null; then
        dirty=" ${YELLOW}*dirty*${NC}"
      fi
      local branch="${REPO_BRANCHES[$i]}"
      if [ "$current_branch" = "$branch" ]; then
        status="${GREEN}ok${NC}${dirty}"
      else
        status="${YELLOW}branch: ${current_branch}${NC}${dirty}"
      fi
    else
      status="${RED}missing${NC}"
      current_branch="-"
    fi

    printf "  %-24s %-22s %-18s %b\n" "$dir" "$feature" "$current_branch" "$status"
  done
  echo ""
}

cmd_update() {
  echo -e "${BOLD}=== Updating All Repositories ===${NC}"
  echo ""
  load_repos_conf

  local i
  for i in "${!REPO_DIRS[@]}"; do
    local dir="${REPO_DIRS[$i]}"
    local target="$DEVTOOLS_DIR/$dir"
    if [ -d "$target/.git" ]; then
      local branch
      branch="$(git -C "$target" branch --show-current 2>/dev/null)"
      info "${dir}: pulling ${branch}..."
      git -C "$target" pull --ff-only 2>&1 | sed 's/^/    /' || warn "  ${dir}: pull failed (conflicts?)"
    fi
  done
  echo ""
  ok "Update complete."
}
