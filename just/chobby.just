set export

DEVTOOLS_DIR := justfile_directory()

# Explicit, reversible writes to the shared chobby_config.json (+ IGL_data.lua).
# Nothing here runs on launch -- you opt in, and back out with the other value.

# Point Chobby's lobby at the local dev teiserver (local) or production (prod).
server target="local":
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    source "$DEVTOOLS_DIR/scripts/chobby-config.sh"
    case "{{target}}" in
      local) addr="localhost" ;;
      prod)  addr="server4.beyondallreason.info" ;;
      *) err "usage: just chobby::server <local|prod>"; exit 1 ;;
    esac
    export BAR_DATA_DIR="${BAR_DATA_DIR:-$(detect_game_dir 2>/dev/null || true)}"
    [ -n "$BAR_DATA_DIR" ] || { err "Could not resolve BAR data dir. Set BAR_DATA_DIR or run 'just setup::init' first."; exit 1; }
    write_env_key BAR_CHOBBY_SERVER "$addr"
    apply_chobby_server
    info "Relaunch Chobby (or 'just bar::launch') to connect to $addr."

# Switch Chobby's gameConfig channel: on -> byar-dev (local .sdd), off -> byar (rapid).
dev-mode target="on":
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    source "$DEVTOOLS_DIR/scripts/setup.sh"
    source "$DEVTOOLS_DIR/scripts/chobby-config.sh"
    export BAR_DATA_DIR="${BAR_DATA_DIR:-$(detect_game_dir 2>/dev/null || true)}"
    [ -n "$BAR_DATA_DIR" ] || { err "Could not resolve BAR data dir. Set BAR_DATA_DIR or run 'just setup::init' first."; exit 1; }
    game_dir="$BAR_DATA_DIR"
    case "{{target}}" in
      on)  channel="byar-dev" ;;
      off) channel="byar" ;;
      *) err "usage: just chobby::dev-mode <on|off>"; exit 1 ;;
    esac
    write_env_key BAR_CHOBBY_CHANNEL "$channel"
    apply_chobby_channel
    if [ "{{target}}" = "on" ]; then
      ensure_devmode_marker "$game_dir"
    else
      rm -f "$game_dir/devmode.txt"
    fi
    info "Relaunch Chobby (or 'just bar::launch') to pick up the change."
