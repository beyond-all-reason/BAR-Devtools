#!/usr/bin/env bash
# Read-only diagnostic checks for BAR-Devtools.
# Expects: DEVTOOLS_DIR, COMPOSE, REPOS_CONF, REPOS_LOCAL (exported by Justfile)

pass_count=0
warn_count=0
fail_count=0

_pass() { ok "$*";   pass_count=$((pass_count + 1)); }
_warn() { warn "$*"; warn_count=$((warn_count + 1)); }
_fail() { err "$*";  fail_count=$((fail_count + 1)); }


check_doctor_deps() {
  echo -e "${BOLD}System dependencies${NC}"

  if ! command -v git &>/dev/null; then
    _fail "git not installed"
    echo "       Run: just setup::deps"
  else
    _pass "git $(git --version | awk '{print $3}')"
  fi

  if ! command -v podman &>/dev/null; then
    _fail "podman not installed"
    echo "       Run: just setup::deps"
  elif ! podman info &>/dev/null; then
    _fail "'podman info' failed (storage init issue?)"
    echo "       Try: podman system reset  (destroys local images)"
  elif ! podman compose version &>/dev/null; then
    _fail "podman compose not functional (install docker-compose or upgrade podman)"
    echo "       Run: just setup::deps"
  elif [ -z "$(_compose_version)" ]; then
    _fail "podman compose using python podman-compose, not the Go docker-compose provider"
    echo "       Run: just setup::deps"
  elif [ ! -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock" ]; then
    _fail "podman API socket not active (docker-compose can't reach the daemon)"
    echo "       Run: systemctl --user enable --now podman.socket  (or just setup::deps)"
  else
    _pass "podman $(podman --version | awk '{print $3}') + compose $(_compose_version) + socket"
  fi

  if ! command -v distrobox &>/dev/null; then
    _warn "distrobox not installed (optional — needed for bar::lint, bar::fmt, lua::*)"
    echo "       Install: just setup::deps"
  else
    _pass "distrobox $(distrobox version 2>/dev/null | head -1)"
  fi

  echo ""
}


check_doctor_env() {
  echo -e "${BOLD}Environment${NC}"

  local env_file="$DEVTOOLS_DIR/.env"
  if [ -f "$env_file" ]; then
    _pass ".env file exists"
  else
    _warn ".env not found (created by just setup::distrobox)"
    echo "       Not required, but recipes needing distrobox won't auto-enter without it."
  fi

  if command -v distrobox &>/dev/null && distrobox list 2>/dev/null | grep -q "$DEVTOOLS_DISTROBOX"; then
    _pass "DEVTOOLS_DISTROBOX=$DEVTOOLS_DISTROBOX (exists)"
  else
    _fail "DEVTOOLS_DISTROBOX=$DEVTOOLS_DISTROBOX (container not found)"
    echo "       Rebuild: just setup::distrobox"
  fi

  # AppImage is a Linux-only boot path; WSL launches the Windows .exe shim.
  if ! is_wsl; then
    local appimage
    appimage="$(read_env_key BAR_APPIMAGE_PATH)"
    if [ -z "$appimage" ]; then
      info "  BAR_APPIMAGE_PATH not set (only needed for AppImage/launcher boots)"
    elif bar_appimage_resolves; then
      _pass "BAR_APPIMAGE_PATH=$appimage (resolves)"
    else
      _warn "BAR_APPIMAGE_PATH=$appimage does not resolve to an AppImage (moved or renamed?)"
      echo "       Fix: just setup::reconfigure"
    fi
  fi

  echo ""
}


check_doctor_wsl() {
  is_wsl || return 0
  echo -e "${BOLD}WSL2${NC}"
  wsl_virtiofs_hint
  echo ""
}


check_doctor_flatpak() {
  if ! command -v flatpak &>/dev/null; then
    _pass "flatpak not installed"
    echo ""
    return
  fi

  if ! flatpak info info.beyondallreason.bar &>/dev/null; then
    _pass "flatpak installed, BAR not installed via flatpak"
    echo ""
    return
  fi

  local ver install_mode
  ver="$(flatpak --version 2>/dev/null || echo "unknown")"
  install_mode="$(flatpak info info.beyondallreason.bar 2>/dev/null | sed -n 's/^Installation: //p')"
  _pass "$ver, info.beyondallreason.bar installed ($install_mode)"

  # Flatpak data dir where devtools symlinks would sit
  local flatpak_data_dir="$HOME/.var/app/info.beyondallreason.bar/data"
  [ -d "$flatpak_data_dir" ] || {
    echo ""
    return
  }

  # Collect permitted filesystem paths from Flatpak permissions (merged).
  # Extract the line: filesystems=path:flag;path;path:ro;...
  # then split on semicolons and strip trailing access-mode flags (:create, :ro, etc).
  local -a permitted=("$flatpak_data_dir")
  local perms_line
  perms_line="$(flatpak info --show-permissions info.beyondallreason.bar 2>/dev/null | sed -n 's/^filesystems=//p')"
  if [ -n "$perms_line" ]; then
    local IFS=';'
    local -a entries=($perms_line)
    local e stripped
    for e in "${entries[@]}"; do
      [ -z "$e" ] && continue
      # Strip access-mode flag after trailing colon
      stripped="${e%:*}"
      # Resolve tilde for ~/ paths and store as-is for absolute paths
      case "$stripped" in
        "~"/*) stripped="$HOME/${stripped#~/}" ;;
        "~")   stripped="$HOME" ;;
      esac
      permitted+=("$stripped")
    done
  fi

  # Check each devtools symlink: is its target inside a permitted path?
  local linked_outside=0
  local -A link_map=(
    [bar]="$flatpak_data_dir/games/Beyond-All-Reason.sdd"
    [chobby]="$flatpak_data_dir/games/BYAR-Chobby.sdd"
    [engine]="$flatpak_data_dir/engine/local-build"
  )
  local name link_path target perm
  for name in bar chobby engine; do
    link_path="${link_map[$name]}"
    [ -L "$link_path" ] || continue

    target="$(readlink "$link_path")"

    # No warning needed if the symlink target is in a flatpak-permitted path
    local covered=0
    for perm in "${permitted[@]}"; do
      case "$target" in
        "$perm"/*|"$perm")
          covered=1
          break
          ;;
      esac
    done

    [ "$covered" -eq 1 ] && continue

    if [ "$linked_outside" -eq 0 ]; then
      _warn "$name symlink target is outside Flatpak sandbox"
      info "  $link_path -> $target"
      linked_outside=1
    else
      info "  $name -> $target (also outside)"
    fi
  done

  if [ "$linked_outside" -gt 0 ]; then
    echo ""
    warn "The Flatpak sandbox blocks the Spring engine from following symlinks"
    warn "into folders it hasn't been granted access to."
    warn "Please grant access to these folders with:"
    if [ "$install_mode" = "system" ]; then
      warn "  sudo flatpak override info.beyondallreason.bar --filesystem=$DEVTOOLS_DIR"
    else
      warn "  flatpak override --user info.beyondallreason.bar --filesystem=$DEVTOOLS_DIR"
    fi
  fi

  echo ""
}


check_doctor_ports() {
  echo -e "${BOLD}Ports${NC}"

  local pg_port="${BAR_POSTGRES_PORT:-5433}"
  local -A port_service=(
    [4000]="Teiserver HTTP"
    [$pg_port]="PostgreSQL"
    [8200]="Spring Protocol TCP"
    [8201]="Spring Protocol TLS"
    [8888]="Teiserver HTTPS"
  )

  local our_ports=""
  if podman compose -f "$DEVTOOLS_DIR/docker-compose.dev.yml" ps --format '{{.Ports}}' 2>/dev/null | grep -q .; then
    our_ports="$(podman compose -f "$DEVTOOLS_DIR/docker-compose.dev.yml" ps --format '{{.Ports}}' 2>/dev/null)"
  fi

  local conflict=0
  for port in 4000 "$pg_port" 8200 8201 8888; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      if echo "$our_ports" | grep -q ":${port}->" 2>/dev/null; then
        continue
      fi
      _warn "Port ${port} in use (${port_service[$port]}) — may conflict"
      conflict=1
    fi
  done

  if [ "$conflict" -eq 0 ]; then
    _pass "All required ports available (4000, ${pg_port}, 8200, 8201, 8888)"
  fi

  echo ""
}


check_doctor_repos() {
  echo -e "${BOLD}Repositories${NC}"

  load_repos_conf

  if [ "${#REPO_DIRS[@]}" -eq 0 ]; then
    _fail "No repositories configured (repos.conf missing or empty)"
    echo "       This shouldn't happen — is repos.conf present?"
    echo ""
    return
  fi

  if [ -f "$REPOS_LOCAL" ]; then
    # col4 is local_path (a path); a non-path value there is a stray feature
    local stray_feature_entries="" dir col4 _
    while read -r dir _ _ col4 _ || [ -n "$dir" ]; do
      case "$dir"  in ''|'#'*|'@'*) continue ;; esac   # blank / comment / directive
      case "$col4" in ''|*/*|'~'*)  continue ;; esac   # empty or a path -> fine
      stray_feature_entries+="       $dir ($col4)"$'\n'
    done < "$REPOS_LOCAL"

    if [ -n "$stray_feature_entries" ]; then
      _warn "Please remove feature flags from repos.local.conf (repos.conf owns them)"
      printf '%s' "$stray_feature_entries"
      echo ""
    fi
  fi

  local i missing_features_set=""
  local -a missing=()
  for i in "${!REPO_DIRS[@]}"; do
    local dir="${REPO_DIRS[$i]}"
    local feature="${REPO_FEATURES[$i]:--}"
    local target="$DEVTOOLS_DIR/$dir"

    if [ -L "$target" ] && [ -d "$target" ]; then
      _pass "${dir} (${feature}) — linked"
    elif [ -d "$target/.git" ]; then
      _pass "${dir} (${feature})"
    else
      missing+=("${dir} (${feature})")
      # collect distinct feature tags for the `just repos::clone` hint
      local IFS=','
      local f
      for f in $feature; do
        [ -z "$f" ] && continue
        case ",$missing_features_set," in
          *",$f,"*) ;;
          *)        missing_features_set="${missing_features_set:+$missing_features_set,}$f" ;;
        esac
      done
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    _warn "${#missing[@]} repos not cloned: ${missing[*]}"
    if [ -n "$missing_features_set" ]; then
      local IFS=','
      local f
      for f in $missing_features_set; do
        echo "       Run: just repos::clone $f"
      done
    fi
    echo "       (Or 'just setup::init' for the interactive picker.)"
  fi

  echo ""
}


check_doctor_images() {
  echo -e "${BOLD}Container images${NC}"

  if ! command -v podman &>/dev/null || ! podman info &>/dev/null; then
    _warn "Skipping — podman not available"
    echo ""
    return
  fi

  local project_name teiserver_image
  project_name="$(basename "$DEVTOOLS_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_-')"
  teiserver_image="${project_name}-teiserver:latest"
  if podman image inspect "$teiserver_image" &>/dev/null; then
    _pass "Teiserver image built"
  elif [ ! -d "$DEVTOOLS_DIR/teiserver" ]; then
    _fail "Teiserver image not built (teiserver repo not cloned)"
    echo "       Run: just repos::clone teiserver && just services::build"
  else
    _fail "Teiserver image not built"
    echo "       Run: just services::build"
  fi

  if podman image inspect "badosu/spads:latest" &>/dev/null; then
    _pass "SPADS image available"
  else
    _warn "SPADS image not pulled (optional)"
    echo "       Run: just services::build"
  fi

  echo ""
}


check_doctor_services() {
  echo -e "${BOLD}Running services${NC}"

  if ! command -v podman &>/dev/null || ! podman info &>/dev/null; then
    _warn "Skipping — podman not available"
    echo ""
    return
  fi

  local compose="podman compose -f $DEVTOOLS_DIR/docker-compose.dev.yml"
  local any_running=0

  for svc in postgres teiserver; do
    local state health
    state="$($compose ps "$svc" --format '{{.State}}' 2>/dev/null)"

    if [ -z "$state" ]; then
      info "  ${svc} — not running"
      continue
    fi

    any_running=1
    health="$($compose ps "$svc" --format '{{.Health}}' 2>/dev/null)"

    if [ "$state" = "running" ] && [ "$health" = "healthy" ]; then
      _pass "${svc} — running (healthy)"
    elif [ "$state" = "running" ] && [ "$health" = "starting" ]; then
      _warn "${svc} — running (still starting)"
    elif [ "$state" = "running" ]; then
      _warn "${svc} — running (health: ${health:-unknown})"
    else
      _fail "${svc} — ${state}"
      echo "       Check: just services::logs ${svc}"
    fi
  done

  local spads_state
  spads_state="$($compose --profile spads ps spads --format '{{.State}}' 2>/dev/null)"
  if [ -n "$spads_state" ]; then
    any_running=1
    if [ "$spads_state" = "running" ]; then
      _pass "spads — running"
    else
      _fail "spads — ${spads_state}"
      echo "       Check: just services::logs spads"
    fi
  else
    info "  spads — not running (optional)"
  fi

  if [ "$any_running" -eq 0 ]; then
    info "  No services running. Start with: just services::up"
  fi

  echo ""
}


check_doctor_game_dir() {
  echo -e "${BOLD}Game directory (.sdd conflicts)${NC}"

  # Same resolution path as `just link` / `just bar` (detect_game_dir).
  local game_dir
  game_dir="$(detect_game_dir 2>/dev/null)" || true
  if [ -z "$game_dir" ]; then
    info "  Game directory not detected (set BAR_DATA_DIR or run just setup::init)."
    echo ""
    return 0
  fi

  local games_dir="$game_dir/games"
  if [ ! -d "$games_dir" ]; then
    info "  No games/ directory at $games_dir"
    echo ""
    return 0
  fi

  # The devtools-managed symlink created by `just link create bar`.
  local dev_symlink="$games_dir/Beyond-All-Reason.sdd"
  local dev_symlink_target=""
  if [ -L "$dev_symlink" ]; then
    dev_symlink_target="$(readlink -f "$dev_symlink" 2>/dev/null || true)"
  fi

  # Recoil recursively scans the games/ root for *.sdd dirs (it descends into
  # every subdir, so a nested copy like tmp_archive/BAR.sdd is a full competitor).
  # -L so the devtools symlink is followed and reported by its link path.
  local -a sdd_paths=()
  while IFS= read -r -d '' p; do
    sdd_paths+=("$p")
  done < <(find -L "$games_dir" -type d -name '*.sdd' -print0 2>/dev/null)

  if [ "${#sdd_paths[@]}" -eq 0 ]; then
    info "  No .sdd directories found under $games_dir"
    echo ""
    return 0
  fi

  # Engine keys games by the `name` in modinfo.lua, NOT the folder name.
  local US=$'\x01'  # unit separator between paths sharing a name
  modinfo_name() {
    local f="$1/modinfo.lua"
    [ -f "$f" ] || return 1
    sed -n "s/^[[:space:]]*name[[:space:]]*=[[:space:]]*[\"']\([^\"']*\)[\"']/\1/p" "$f" | head -n1
  }

  # name -> "path1<US>path2..."  (unit separator between paths)
  local -A by_name=()
  local path name
  for path in "${sdd_paths[@]}"; do
    name="$(modinfo_name "$path")"
    if [ -z "$name" ]; then
      info "  $path has no modinfo.lua name (engine will skip it)"
      continue
    fi
    if [ -n "${by_name[$name]+x}" ]; then
      by_name[$name]="${by_name[$name]}${US}${path}"
    else
      by_name[$name]="$path"
    fi
  done

  local collision=0
  for name in "${!by_name[@]}"; do
    local IFS="$US"
    local -a members=("${by_name[$name]}")
    if [ "${#members[@]}" -lt 2 ]; then
      continue
    fi
    collision=1

    # Check 3: generic same-name collision — engine loads only one by scan order.
    _warn "Multiple .sdd folders share the game name \"$name\":"
    local m
    for m in "${members[@]}"; do
      info "    $m"
    done
    info "  Recoil loads only ONE of these (by scan order); the rest are ignored."

    # Check 4: the devtools symlink is one of the competitors — its branch/
    # feature changes may be silently overridden by the other copy.
    local dev_shadowed=0
    for m in "${members[@]}"; do
      if [ "$m" = "$dev_symlink" ]; then
        dev_shadowed=1; break
      fi
      if [ -n "$dev_symlink_target" ] && [ "$(readlink -f "$m" 2>/dev/null || echo "$m")" = "$dev_symlink_target" ]; then
        dev_shadowed=1; break
      fi
    done

    if [ "$dev_shadowed" -eq 1 ]; then
      warn "Your devtools symlink ($dev_symlink) is competing with another copy."
      warn "The engine may load the OTHER copy, so branch/feature changes in your"
      warn "linked repo will appear ignored. Delete the competing .sdd (e.g. a"
      warn "nested copy like tmp_archive/BAR.sdd) and re-run the game."
    fi
    echo ""
  done

  if [ "$collision" -eq 0 ]; then
    _pass "No competing .sdd folders (${#sdd_paths[@]} found, all distinct game names)"
  fi

  echo ""
}


check_doctor_modules() {
  if [ "${#SETUP_MODULES[@]}" -eq 0 ]; then
    return 0
  fi
  echo -e "${BOLD}Setup modules${NC}"
  doctor_modules
  echo ""
}

cmd_doctor() {
  echo -e "${BOLD}=== BAR Devtools Doctor ===${NC}"
  echo ""

  check_doctor_deps
  check_doctor_env
  check_doctor_wsl
  check_doctor_flatpak
  check_doctor_game_dir
  check_doctor_modules
  check_doctor_ports
  check_doctor_repos
  check_doctor_images
  check_doctor_services

  echo -e "${BOLD}Summary${NC}"
  local summary=""
  summary+="${GREEN}${pass_count} passed${NC}"
  if [ "$warn_count" -gt 0 ]; then
    summary+=", ${YELLOW}${warn_count} warnings${NC}"
  fi
  if [ "$fail_count" -gt 0 ]; then
    summary+=", ${RED}${fail_count} failures${NC}"
  fi
  echo -e "  ${summary}"

  if [ "$fail_count" -gt 0 ]; then
    echo ""
    echo "  Fix failures above, then re-run: just doctor"
    return 1
  elif [ "$warn_count" -gt 0 ]; then
    echo ""
    echo "  Warnings are non-blocking but may affect some workflows."
  fi
}
