#!/usr/bin/env bash
# Force Chobby's gameConfig channel ("byar-dev" vs "byar") to a known value.
#
# Chobby reads its channel from TWO places that disagree on subsequent
# launches, and a naive "just write chobby_config.json" only fixes the first
# of them. Both have to be in sync or the dropdown silently reverts:
#
#   1. <data-dir>/chobby_config.json, "game" field.
#      Read by liblobby_configuration.lua at startup and assigned as the
#      INITIAL Configuration.gameConfigName in chobby/components/configuration.lua
#      (`self.gameConfigName = fileConfig.game`). This is the only thing
#      that matters on a fresh install.
#
#   2. <data-dir>/LuaMenu/Config/IGL_data.lua, ["Chili lobby"].gameConfigName.
#      Once Chobby has saved any widget state, Spring/Chobby's widget loader
#      calls Configuration:SetConfigData() with that table AFTER init, which
#      iterates and calls SetConfigValue("gameConfigName", <saved>) -- so the
#      saved value clobbers whatever (1) just put there. This is what bit us:
#      chobby_config.json said "byar-dev" but IGL_data.lua said "byar", so the
#      dropdown stayed on "Beyond All Reason" (rapid build) and the local .sdd
#      never loaded until the user manually picked it in Chobby's settings.
#
# So "set the channel" is really "write both, idempotent". That's
# set_chobby_channel below. apply_chobby_channel (setup module) and
# bar::launch's preflight both call it. Chobby rewrites IGL_data.lua wholesale
# on shutdown using self.gameConfigName, so our patch round-trips correctly
# (Chobby reads it on init, gets clobbered to itself by SetConfigData, writes
# itself back on save).

# Read $1's "game" field from a chobby_config.json. Empty if file missing
# or the field is absent. The JSON Chobby ships is flat enough that we
# don't need a full parser here -- the field always lives at the top level.
_chobby_game_field() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0
    grep -oE '"game"[[:space:]]*:[[:space:]]*"[^"]+"' "$cfg" 2>/dev/null \
        | sed -E 's/.*"([^"]+)"$/\1/' | tr -d '\r' | head -n1
}

# Write/patch chobby_config.json so its "game" field equals $2. Preserves
# other fields (server, etc.) by round-tripping through python's json.
# Idempotent at the byte level: if the file would round-trip to identical
# bytes, no write happens. Important on /mnt/c where each write is a drvfs
# round-trip and bumps mtime (which propagates through sync/inotify chains).
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

# Echo the persisted gameConfigName under ["Chili lobby"] in
# <data-dir>/LuaMenu/Config/IGL_data.lua. Empty if the file/block/field is
# missing (which is the usual fresh-install state). read_bytes/decode keeps
# CRLF intact in the string; the regex doesn't care.
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

# Patch ["Chili lobby"].gameConfigName in IGL_data.lua to $2. No-op if the
# file is missing (fresh install -- chobby_config.json default suffices),
# if the block is absent, if the field is absent (Chobby will write it
# itself on next save), or if it already matches. Round-trips through
# read_bytes/write_bytes so CRLF (Spring writes the file from Windows) is
# preserved verbatim instead of getting flattened to LF.
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

# Force both chobby state files to agree that the channel is $2.
# Idempotent. Returns 0 always (best-effort writes -- callers shouldn't
# abort on a missing data dir or read-only filesystem).
set_chobby_channel() {
    local data_dir="$1" game="$2"
    [ -n "$data_dir" ] && [ -n "$game" ] || return 0
    _write_chobby_game        "$data_dir/chobby_config.json"   "$game"
    _write_chobby_widget_game "$data_dir"                      "$game"
}
