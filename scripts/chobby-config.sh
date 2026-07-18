#!/usr/bin/env bash
# Force Chobby's gameConfig channel ("byar-dev" vs "byar") to a known value.
#
# Chobby stores the channel in two files that must agree, or the dropdown
# silently reverts: chobby_config.json ("game" field, used on fresh install)
# and LuaMenu/Config/IGL_data.lua (["Chili lobby"].gameConfigName, written
# once widget state exists and clobbers chobby_config.json after init).
# set_chobby_channel writes both, idempotently.

_chobby_game_field() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0
    grep -oE '"game"[[:space:]]*:[[:space:]]*"[^"]+"' "$cfg" 2>/dev/null \
        | sed -E 's/.*"([^"]+)"$/\1/' | tr -d '\r' | head -n1
}

# patch chobby_config.json "game" field to $2; byte-idempotent (matters on
# /mnt/c where any write bumps mtime through sync/inotify chains)
_write_chobby_game() {
    local cfg="$1" game="$2"
    python3 - "$cfg" "$game" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
game = sys.argv[2]
data = {}
if p.exists():
    try:
        data = json.loads(p.read_text())
    except Exception:
        data = {}
data["game"] = game
new = json.dumps(data, indent=2) + "\n"
if p.exists() and p.read_text() == new:
    sys.exit(0)
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(new)
PY
}

# echo persisted ["Chili lobby"].gameConfigName from IGL_data.lua; empty if absent
_chobby_widget_game_field() {
    local data_dir="$1"
    local f="$data_dir/LuaMenu/Config/IGL_data.lua"
    [ -f "$f" ] || return 0
    python3 - "$f" 2>/dev/null <<'PY' || true
import re, sys, pathlib
text = pathlib.Path(sys.argv[1]).read_bytes().decode('utf-8', errors='replace')
i = text.find('["Chili lobby"]')
if i < 0: sys.exit(0)
j = text.find('{', i)
if j < 0: sys.exit(0)
depth, end = 0, -1
for k in range(j, len(text)):
    c = text[k]
    if c == '{': depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0:
            end = k
            break
if end < 0: sys.exit(0)
m = re.search(r'\bgameConfigName\s*=\s*"([^"]*)"', text[j:end+1])
if m: print(m.group(1))
PY
}

# patch ["Chili lobby"].gameConfigName in IGL_data.lua to $2; no-op if absent.
# round-trips bytes to preserve CRLF (Spring writes the file from Windows)
_write_chobby_widget_game() {
    local data_dir="$1" game="$2"
    local f="$data_dir/LuaMenu/Config/IGL_data.lua"
    [ -f "$f" ] || return 0
    python3 - "$f" "$game" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
desired = sys.argv[2]
raw = p.read_bytes()
text = raw.decode('utf-8', errors='replace')
i = text.find('["Chili lobby"]')
if i < 0: sys.exit(0)
j = text.find('{', i)
if j < 0: sys.exit(0)
depth, end = 0, -1
for k in range(j, len(text)):
    c = text[k]
    if c == '{': depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0:
            end = k
            break
if end < 0: sys.exit(0)
block = text[j:end+1]
new_block, n = re.subn(
    r'(\bgameConfigName\s*=\s*)"[^"]*"',
    lambda m: m.group(1) + '"' + desired + '"',
    block, count=1,
)
if n == 0 or new_block == block:
    sys.exit(0)
new_raw = (text[:j] + new_block + text[end+1:]).encode('utf-8')
if new_raw != raw:
    p.write_bytes(new_raw)
PY
}

# force both chobby state files to channel $2; best-effort, always returns 0
set_chobby_channel() {
    local data_dir="$1" game="$2"
    [ -n "$data_dir" ] && [ -n "$game" ] || return 0
    _write_chobby_game        "$data_dir/chobby_config.json"   "$game"
    _write_chobby_widget_game "$data_dir"                      "$game"
}

# write BAR_CHOBBY_CHANNEL into the chobby state files; idempotent. Explicit
# opt-in only (just bar::dev-mode) -- nothing else mutates the shared install.
apply_chobby_channel() {
    local data_dir desired current widget_current
    data_dir="${BAR_DATA_DIR:-$(read_env_key BAR_DATA_DIR)}"
    [ -n "$data_dir" ] || return 0
    desired="$(read_env_key BAR_CHOBBY_CHANNEL)"
    [ -n "$desired" ] || return 0

    current="$(_chobby_game_field "$data_dir/chobby_config.json")"
    widget_current="$(_chobby_widget_game_field "$data_dir")"
    if [ "$current" = "$desired" ] && { [ -z "$widget_current" ] || [ "$widget_current" = "$desired" ]; }; then
        return 0
    fi
    set_chobby_channel "$data_dir" "$desired"
    ok "Chobby gameConfig set to $desired (chobby_config.json + IGL_data.lua)"
}

# echo server.address from chobby_config.json; empty if absent
_chobby_server_field() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0
    python3 - "$cfg" 2>/dev/null <<'PY' || true
import json, sys, pathlib
try:
    print((json.loads(pathlib.Path(sys.argv[1]).read_text()).get("server") or {}).get("address", ""))
except Exception:
    pass
PY
}

# patch chobby_config.json server.address to $2; byte-idempotent, seeds port/protocol on a fresh file
_write_chobby_server() {
    local cfg="$1" addr="$2"
    python3 - "$cfg" "$addr" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); addr = sys.argv[2]
data = {}
if p.exists():
    try: data = json.loads(p.read_text())
    except Exception: data = {}
srv = data.get("server")
srv = srv if isinstance(srv, dict) else {}
srv["address"] = addr
srv.setdefault("port", 8200); srv.setdefault("protocol", "spring"); srv.setdefault("serverName", "BAR")
data["server"] = srv
new = json.dumps(data, indent=2) + "\n"
if p.exists() and p.read_text() == new:
    sys.exit(0)
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(new)
PY
}

# patch ["Chili lobby"].serverAddress in IGL_data.lua to $2; no-op if absent (CRLF-safe)
_write_chobby_widget_server() {
    local data_dir="$1" addr="$2"
    local f="$data_dir/LuaMenu/Config/IGL_data.lua"
    [ -f "$f" ] || return 0
    python3 - "$f" "$addr" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); desired = sys.argv[2]
raw = p.read_bytes(); text = raw.decode('utf-8', errors='replace')
i = text.find('["Chili lobby"]')
if i < 0: sys.exit(0)
j = text.find('{', i)
if j < 0: sys.exit(0)
depth, end = 0, -1
for k in range(j, len(text)):
    c = text[k]
    if c == '{': depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0:
            end = k; break
if end < 0: sys.exit(0)
block = text[j:end+1]
new_block, n = re.subn(r'(\bserverAddress\s*=\s*)"[^"]*"', lambda m: m.group(1) + '"' + desired + '"', block, count=1)
if n == 0 or new_block == block: sys.exit(0)
new_raw = (text[:j] + new_block + text[end+1:]).encode('utf-8')
if new_raw != raw: p.write_bytes(new_raw)
PY
}

# force both chobby state files to lobby server $2; best-effort, always returns 0
set_chobby_server() {
    local data_dir="$1" addr="$2"
    [ -n "$data_dir" ] && [ -n "$addr" ] || return 0
    _write_chobby_server        "$data_dir/chobby_config.json" "$addr"
    _write_chobby_widget_server "$data_dir"                    "$addr"
}

# write BAR_CHOBBY_SERVER into the chobby state files; idempotent. Explicit opt-in only.
apply_chobby_server() {
    local data_dir desired
    data_dir="${BAR_DATA_DIR:-$(read_env_key BAR_DATA_DIR)}"
    [ -n "$data_dir" ] || return 0
    desired="$(read_env_key BAR_CHOBBY_SERVER)"
    [ -n "$desired" ] || return 0
    set_chobby_server "$data_dir" "$desired"
    ok "Chobby lobby server set to $desired (chobby_config.json + IGL_data.lua)"
}
