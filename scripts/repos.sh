#!/usr/bin/env bash
# Repository management helpers. Source scripts/common.sh before this file.
# Expects: DEVTOOLS_DIR, REPOS_CONF, REPOS_LOCAL (exported by Justfile)

declare -a REPO_DIRS=() REPO_URLS=() REPO_UPSTREAM_URLS=() REPO_BRANCHES=() REPO_FEATURES=() REPO_LOCAL_PATHS=()

_apply_protocol() {
  local url="$1" protocol="$2"
  if [ "$protocol" = "ssh" ] && [[ "$url" =~ ^https://github\.com/(.+)$ ]]; then
    echo "git@github.com:${BASH_REMATCH[1]}"
  elif [ "$protocol" = "https" ] && [[ "$url" =~ ^git@github\.com:(.+)$ ]]; then
    echo "https://github.com/${BASH_REMATCH[1]}"
  else
    echo "$url"
  fi
}

load_repos_conf() {
  REPO_DIRS=(); REPO_URLS=(); REPO_UPSTREAM_URLS=(); REPO_BRANCHES=(); REPO_FEATURES=(); REPO_LOCAL_PATHS=()
  local -A seen=() base_urls=() seen_in_file=() directive_seen=()
  local local_root="" protocol=""

  _parse_conf() {
    local file="$1" is_base="$2"
    [ -f "$file" ] || return 0
    seen_in_file=(); directive_seen=()
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      line="${line%%#*}"
      line="$(echo "$line" | xargs 2>/dev/null || true)"
      [ -z "$line" ] && continue

      # directive lines: @key value
      if [[ "$line" =~ ^@([a-z_]+)[[:space:]]+(.+)$ ]]; then
        local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
        case "$key" in
          local_root) local_root="${val/#\~/$HOME}" ;;
          protocol)   protocol="$val" ;;
          *)          warn "Unknown directive in $file: @$key"; continue ;;
        esac
        [ -n "${directive_seen[$key]:-}" ] && warn "  ${file##*/}: @$key set more than once -- using '$val'"
        directive_seen[$key]=1
        continue
      fi

      local dir url branch feature local_path
      read -r dir url branch feature local_path <<< "$line"
      [ -z "$dir" ] && continue
      local_path="${local_path/#\~/$HOME}"
      local raw_url="$url" raw_branch="$branch" raw_feature="$feature" raw_local_path="$local_path"

      # repos.conf URL is canonical; repos.local.conf overrides per blank column
      if [ "$is_base" = "1" ] && [ -n "$url" ]; then
        base_urls[$dir]="$url"
      fi

      local prev_url="" prev_branch="" prev_feature="" prev_local_path=""
      if [ -n "${seen[$dir]:-}" ]; then
        IFS='|' read -r prev_url prev_branch prev_feature prev_local_path <<< "${seen[$dir]}"
      fi
      url="${url:-$prev_url}"
      branch="${branch:-${prev_branch:-master}}"
      feature="${feature:-$prev_feature}"
      local_path="${local_path:-$prev_local_path}"
      [ -z "$url" ] && continue

      if [ -n "${seen_in_file[$dir]:-}" ]; then
        warn "  ${file##*/}: duplicate entry for '$dir' -- using the last one"
      elif [ -n "${seen[$dir]:-}" ]; then
        local changes=""
        [ -n "$raw_url" ]        && [ "$raw_url" != "$prev_url" ]               && changes+=" url=$raw_url"
        [ -n "$raw_branch" ]     && [ "$raw_branch" != "$prev_branch" ]         && changes+=" branch=$prev_branch->$raw_branch"
        [ -n "$raw_feature" ]    && [ "$raw_feature" != "$prev_feature" ]       && changes+=" feature=$raw_feature"
        [ -n "$raw_local_path" ] && [ "$raw_local_path" != "$prev_local_path" ] && changes+=" local_path=$raw_local_path"
        [ -n "$changes" ] && info "  $dir: local override --$changes"
      fi
      seen_in_file[$dir]=1

      seen[$dir]="$url|$branch|$feature|$local_path"
    done < "$file"
  }

  _parse_conf "$REPOS_CONF" 1
  _parse_conf "$REPOS_LOCAL" 0

  local dir
  for dir in "${!seen[@]}"; do
    local url branch feature local_path upstream_url=""
    IFS='|' read -r url branch feature local_path <<< "${seen[$dir]}"

    url="$(_apply_protocol "$url" "$protocol")"
    if [ -n "${base_urls[$dir]:-}" ]; then
      local base_url
      base_url="$(_apply_protocol "${base_urls[$dir]}" "$protocol")"
      # only a separate `upstream` when canonical differs from origin
      if [ "$base_url" != "$url" ]; then
        upstream_url="$base_url"
      fi
    fi

    if [ -z "$local_path" ] && [ -n "$local_root" ]; then
      local_path="$local_root/$dir"
    fi

    REPO_DIRS+=("$dir")
    REPO_URLS+=("$url")
    REPO_UPSTREAM_URLS+=("$upstream_url")
    REPO_BRANCHES+=("$branch")
    REPO_FEATURES+=("$feature")
    REPO_LOCAL_PATHS+=("$local_path")
  done
}

# host/owner/repo, ignoring scheme (https/ssh/scp) and a trailing .git
_normalize_remote_url() {
  local u="${1%.git}"; u="${u%/}"
  if [[ "$u" =~ ^[^@/]+@([^:/]+):(.+)$ ]]; then
    u="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"   # git@host:owner/repo
  else
    u="${u#*://}"; u="${u#*@}"                  # scheme://[user@]host/owner/repo
  fi
  printf '%s' "$u"
}

# warn (don't touch) when an existing repo's remotes don't match config
verify_remotes() {
  local dir="$1" target="$2" url="$3" upstream_url="$4"
  [ -d "$target/.git" ] || return 0

  local origin_url upstream_remote_url
  origin_url="$(git -C "$target" remote get-url origin 2>/dev/null || true)"
  upstream_remote_url="$(git -C "$target" remote get-url upstream 2>/dev/null || true)"

  local n_origin n_upstream n_url n_upstream_url
  n_origin="$(_normalize_remote_url "$origin_url")"
  n_upstream="$(_normalize_remote_url "$upstream_remote_url")"
  n_url="$(_normalize_remote_url "$url")"
  n_upstream_url="$(_normalize_remote_url "$upstream_url")"

  local complaint=""
  if [ -n "$upstream_url" ]; then
    if [ "$n_origin" != "$n_url" ] || [ "$n_upstream" != "$n_upstream_url" ]; then
      complaint="expected origin=${url}, upstream=${upstream_url}"
    fi
  else
    # tolerate the legacy layout where origin (and only origin) is canonical
    if [ -n "$upstream_remote_url" ] && [ "$n_upstream" != "$n_url" ]; then
      complaint="expected upstream=${url}"
    elif [ -z "$upstream_remote_url" ] && [ -n "$origin_url" ] && [ "$n_origin" != "$n_url" ]; then
      complaint="expected upstream=${url}"
    fi
  fi

  if [ -n "$complaint" ]; then
    warn "  ${dir}: remotes don't match config (${complaint})"
    [ -n "$origin_url" ]          && warn "    origin   = ${origin_url}"
    [ -n "$upstream_remote_url" ] && warn "    upstream = ${upstream_remote_url}"
    warn "    run \`just repos::standardize-remotes\` to normalize"
  fi
}

fetch_all_remotes() {
  local dir="$1" target="$2"
  local remote
  while read -r remote; do
    [ -z "$remote" ] && continue
    git -C "$target" fetch "$remote" --tags --quiet 2>/dev/null \
      || warn "  ${dir}: fetch ${remote} failed (offline or auth?)"
  done < <(git -C "$target" remote)
}

# fresh checkouts only
do_clone() {
  local dir="$1" url="$2" branch="$3" upstream_url="$4" target="$5"
  local origin_name="origin"
  # no fork override -> canonical is our only remote, name it `upstream`
  [ -z "$upstream_url" ] && origin_name="upstream"

  info "  ${dir}: cloning ${url} as ${origin_name} (branch: ${branch})..."
  mkdir -p "$(dirname "$target")"
  if ! git clone --origin "$origin_name" --recurse-submodules --branch "$branch" "$url" "$target" 2>&1 | sed 's/^/    /'; then
    err "  ${dir}: clone failed (check URL / SSH access)"
    return 1
  fi
  if [ -n "$upstream_url" ]; then
    info "  ${dir}: adding upstream -> ${upstream_url}"
    git -C "$target" remote add upstream "$upstream_url"
    git -C "$target" fetch upstream --tags --quiet 2>/dev/null \
      || warn "  ${dir}: upstream fetch failed (offline or auth?)"
  fi
}

# normalize an existing repo's remotes; warns and skips unrecognized layouts
fixup_remotes() {
  local dir="$1" target="$2" url="$3" upstream_url="$4"
  [ -d "$target/.git" ] || return 0

  local origin_url upstream_remote_url
  origin_url="$(git -C "$target" remote get-url origin 2>/dev/null || true)"
  upstream_remote_url="$(git -C "$target" remote get-url upstream 2>/dev/null || true)"

  if [ -n "$upstream_url" ]; then
    if [ "$origin_url" = "$url" ] && [ "$upstream_remote_url" = "$upstream_url" ]; then
      ok "  ${dir}: already normalized"
      return 0
    fi
    if [ "$origin_url" = "$url" ] && [ -z "$upstream_remote_url" ]; then
      info "  ${dir}: adding upstream=${upstream_url}"
      git -C "$target" remote add upstream "$upstream_url"
    elif [ "$origin_url" = "$upstream_url" ] && [ -z "$upstream_remote_url" ]; then
      info "  ${dir}: renaming origin -> upstream and adding origin=${url}"
      git -C "$target" remote rename origin upstream
      git -C "$target" remote add origin "$url"
    elif [ "$origin_url" = "$upstream_url" ] && [ "$upstream_remote_url" = "$url" ]; then
      info "  ${dir}: swapping inverted origin/upstream URLs"
      git -C "$target" remote set-url origin "$url"
      git -C "$target" remote set-url upstream "$upstream_url"
    else
      warn "  ${dir}: unrecognized remote layout, skipping"
      [ -n "$origin_url" ]          && warn "    origin   = ${origin_url}"
      [ -n "$upstream_remote_url" ] && warn "    upstream = ${upstream_remote_url}"
      warn "    expected origin=${url}, upstream=${upstream_url}"
      return 0
    fi
    git -C "$target" fetch upstream --tags --quiet 2>/dev/null \
      || warn "  ${dir}: upstream fetch failed (offline or auth?)"
  else
    if [ "$upstream_remote_url" = "$url" ]; then
      ok "  ${dir}: already normalized"
      return 0
    fi
    if [ -z "$upstream_remote_url" ] && [ "$origin_url" = "$url" ]; then
      info "  ${dir}: renaming origin -> upstream"
      git -C "$target" remote rename origin upstream
    else
      warn "  ${dir}: unrecognized remote layout, skipping"
      [ -n "$origin_url" ]          && warn "    origin   = ${origin_url}"
      [ -n "$upstream_remote_url" ] && warn "    upstream = ${upstream_remote_url}"
      warn "    expected upstream=${url}"
      return 0
    fi
    git -C "$target" fetch upstream --tags --quiet 2>/dev/null \
      || warn "  ${dir}: upstream fetch failed (offline or auth?)"
  fi
}

clone_or_update_repo() {
  local dir="$1" url="$2" branch="$3" upstream_url="$4" local_path="${5:-}" target="$DEVTOOLS_DIR/$dir"

  # config wants a symlink: workspace slot -> external checkout
  if [ -n "$local_path" ]; then
    mkdir -p "$(dirname "$local_path")"

    if [ ! -L "$target" ] && [ -d "$target" ]; then
      if [ -d "$target/.git" ] && [ ! -d "$local_path" ]; then
        # workspace copy is the repo and canonical slot is free: promote it
        info "  ${dir}: moving workspace checkout -> ${local_path}"
        mv "$target" "$local_path" || { err "  ${dir}: move failed"; return 1; }
      else
        # move aside so we never delete user data
        local backup="$DEVTOOLS_DIR/.backups/${dir}-$(date +%Y%m%d-%H%M%S)"
        warn "  ${dir}: workspace has a real directory where config wants a symlink"
        info "  ${dir}: backing it up -> ${backup}"
        mkdir -p "$DEVTOOLS_DIR/.backups"
        mv "$target" "$backup" || { err "  ${dir}: backup move failed"; return 1; }
      fi
    fi

    if [ ! -d "$local_path" ]; then
      do_clone "$dir" "$url" "$branch" "$upstream_url" "$local_path" || return 1
    else
      verify_remotes "$dir" "$local_path" "$url" "$upstream_url"
    fi

    if [ -L "$target" ]; then
      local current_link
      current_link="$(readlink "$target")"
      if [ "$current_link" = "$local_path" ]; then
        ok "  ${dir}: linked -> ${local_path}"
      else
        info "  ${dir}: repointing symlink (${current_link} -> ${local_path})"
        rm "$target"
        ln -s "$local_path" "$target"
        ok "  ${dir}: linked -> ${local_path}"
      fi
    else
      ln -s "$local_path" "$target"
      ok "  ${dir}: linked -> ${local_path}"
    fi
    return 0
  fi

  # config wants an in-place clone: workspace slot is the checkout
  if [ -L "$target" ]; then
    local dest
    dest="$(readlink "$target")"
    warn "  ${dir}: workspace is a symlink but config says clone-in-place"
    rm "$target"
    if [ -d "$dest/.git" ]; then
      info "  ${dir}: moving ${dest} into the workspace"
      mv "$dest" "$target" || { err "  ${dir}: move failed"; return 1; }
    fi
  fi

  if [ -d "$target/.git" ]; then
    verify_remotes "$dir" "$target" "$url" "$upstream_url"
    info "  ${dir}: fetching latest..."
    fetch_all_remotes "$dir" "$target"
    git -C "$target" submodule update --init --recursive --quiet 2>/dev/null \
      || warn "  ${dir}: submodule sync failed (offline or auth?)"
    local current_branch
    current_branch="$(git -C "$target" branch --show-current 2>/dev/null)"
    if [ -n "$current_branch" ] && [ "$current_branch" != "$branch" ]; then
      info "  ${dir}: on branch '${current_branch}' (config says '${branch}')"
    fi
  else
    do_clone "$dir" "$url" "$branch" "$upstream_url" "$target"
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
    local upstream_url="${REPO_UPSTREAM_URLS[$i]}"
    local branch="${REPO_BRANCHES[$i]}"
    local feature="${REPO_FEATURES[$i]}"
    local local_path="${REPO_LOCAL_PATHS[$i]}"

    if [ "$feature_filter" != "all" ] && ! features_include "$feature" "$feature_filter"; then
      skipped=$((skipped + 1))
      continue
    fi

    if [ -n "$local_path" ]; then
      clone_or_update_repo "$dir" "$url" "$branch" "$upstream_url" "$local_path"
      linked=$((linked + 1))
    elif [ -d "$DEVTOOLS_DIR/$dir/.git" ]; then
      clone_or_update_repo "$dir" "$url" "$branch" "$upstream_url"
      updated=$((updated + 1))
    else
      clone_or_update_repo "$dir" "$url" "$branch" "$upstream_url"
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
      fetch_all_remotes "$dir" "$target"
    fi
  done
  echo ""
  ok "Update complete."
}

cmd_standardize_remotes() {
  load_repos_conf

  echo -e "${BOLD}=== Normalizing Repository Remotes ===${NC}"
  echo ""
  info "Target: origin = fork (repos.local.conf), upstream = canonical (repos.conf)."
  info "Repos with no fork: single remote \`upstream\` = canonical."
  echo ""

  local i
  for i in "${!REPO_DIRS[@]}"; do
    local dir="${REPO_DIRS[$i]}"
    local url="${REPO_URLS[$i]}"
    local upstream_url="${REPO_UPSTREAM_URLS[$i]}"
    local local_path="${REPO_LOCAL_PATHS[$i]}"
    local repo_path="$DEVTOOLS_DIR/$dir"
    [ -n "$local_path" ] && repo_path="$local_path"
    [ -d "$repo_path/.git" ] || continue
    fixup_remotes "$dir" "$repo_path" "$url" "$upstream_url"
  done
  echo ""
  ok "Fixup complete."
}
