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
