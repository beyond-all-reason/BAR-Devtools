---
name: bar-codemod-prereq
description: >-
  Diagnose and fix BAR codemod transform failures by creating prereq branches,
  and resolve LuaLS type errors on the mig-manual branch.
  Covers generate-branches.sh, the prereq branch pattern, widget sandbox architecture,
  full_moon AST gotchas, and 38+ type error categories with idempotent fix procedures.
  Categories are written so subagents can re-run them on a fresh master+transforms branch.
---

# BAR Codemod Prereq Skill

## Audience

This document serves two audiences:

- **Orchestrator** (human or `generate-branches.sh`): Manages `.luarc.json`, engine C++
  annotations, `just lua::library`, and `types/` stubs. Subagents cannot do these.
- **Subagents**: Apply mechanical BAR-side Lua fixes only. Assume `recoil-lua-library`
  stubs and `types/` are correct and static. Never edit `.luarc.json`, engine C++, or
  regenerate stubs. Report gaps as uncategorized findings for orchestrator triage.

Sections marked **(orchestrator)** are reference for the orchestrator. Sections marked
**(subagent)** contain instructions subagents execute directly.

**Clean-tree caveat:** `git stash -u` on `mig-manual` drops the whole prereq surface
(`.luarc.json`, `types/*`, mass Lua edits). `just bar::check` then jumps back to
~10k problems — that is expected. Subagent dry-runs should use **partial stashes** or a
branch that keeps orchestrator commits while dropping only experimental BAR edits.

## Branch Architecture

`generate-branches.sh` deterministically rebuilds all branches from `origin/master`. Each transform declares a branch, commit message, PR URL, and optional prereq.

```
origin/master
 ├─ fmt                    (stylua)
 ├─ mig-bracket            (bracket-to-dot)
 ├─ mig-rename-aliases     (rename-aliases)
 ├─ mig-detach-bar-modules (detach-bar-modules)
 ├─ mig-spring-split       (spring-split)
 ├─ mig-i18n               (i18n-kikito)
 └─ mig                    (all transforms sequentially)
```

Each leaf targets `master` independently. `mig` applies all transforms in sequence.

## The Prereq Branch Pattern

When a transform needs companion changes the codemod can't generate (sandbox wiring, config, type stubs, dependencies), put them on a **prereq branch**. The script cherry-picks it before the codemod runs.

### build_leaf sequence

1. `git checkout -B $branch origin/master`
2. `git cherry-pick origin/master..$prereq` (if prereq set)
3. Run codemod, `git add -A && git commit`
4. Run `post_commit_*` (if defined)
5. Run tests

### build_mig

Deduplicates prereqs across transforms, cherry-picks all unique ones, then runs each transform sequentially.

### Constraints

1. **Prereq must be harmless on master.** `Utilities = Utilities` in `system.lua` captures `nil` on master but the real table after the codemod transforms `init.lua`.
2. **Codemod must not clobber prereq.** Don't put patterns the codemod matches in prereq files.
3. **No post-transform cruft.** If a workaround is needed (e.g. `_G.Utilities = _G.Spring.Utilities`), fix the codemod to handle it natively instead.

### Existing prereqs

| Branch | Transform | Purpose |
|--------|-----------|---------|
| `stylua` | `fmt` | `.stylua.toml`, `.styluaignore`, CI |
| `detach-bar-modules-env` | `detach_bar_modules` | System table entries, `.luarc.json` globals, type stubs |
| `lux-i18n` | `i18n_kikito` | Add `kikito/i18n.lua` lux dependency |

## Diagnosing Failures

### Runtime: "attempt to index global 'X' (a nil value)"

Widgets run in sandboxed environments via `setfenv` with `__index = System`. The `System` table is in `luaui/system.lua` / `luarules/system.lua`. If a codemod introduces a bare global not in `System`, widgets get `nil`.

**Fix:** Add `X = X` to both `system.lua` files via a prereq branch.

### Sandbox execution order

```
init.lua        -> sets globals (Utilities, I18N, etc.)
barwidgets.lua  -> loads system.lua -> builds System table
                -> setfenv(widget_chunk, widget) where widget.__index = System
```

`Spring` is in `System`, so `Spring.X` always works. Bare `X` only works if added to `System`.

### Unit tests: stubs not transformed

Test stubs in `spec/builders/` use `_G.Spring.X = ...`. The full_moon AST parses `_G.Spring.Utilities` as prefix=`_G`, suffixes=[`.Spring`, `.Utilities`]. Codemods matching prefix=`Spring` will miss this.

**Fix:** Extend the codemod to also match prefix `_G` + first suffix `.Spring` + second suffix `.Module`. Preferred over adding aliases in the prereq.

### LSP: undefined-global warnings

After introducing new globals, add to prereq:
1. `.luarc.json` `diagnostics.globals` array
2. Type stubs in `types/` based on actual implementations (read `common/springFunctions.lua`, `modules/lava.lua`, etc.)

## Workflow

1. **Reproduce** -- run `just bar::fmt-mig-generate`, check test output and/or run integration tests
2. **Diagnose** -- match error pattern to one of the categories below
3. **Create prereq branch** -- `git checkout -B prereq-name origin/master`, make changes, commit
4. **Wire it** -- set `transform_prereq="prereq-name"` in `generate-branches.sh`
5. **Fix codemod if needed** -- extend AST matching (e.g. `_G.Spring.X` pattern), run `cargo test`, `cargo build --release`
6. **Regenerate** -- `just bar::fmt-mig-generate`, verify all branches pass
7. **Push** -- `just bar::fmt-mig-generate --push --update-prs`

## full_moon AST Reference

`_G.Spring.Utilities.Foo()` parses as:
- prefix: `_G`
- suffixes: [`.Spring`, `.Utilities`, `.Foo`, `()`]

`Spring.Utilities.Foo()` parses as:
- prefix: `Spring`
- suffixes: [`.Utilities`, `.Foo`, `()`]

Both must be handled. See `detach_bar_modules.rs` `try_rewrite` for the two-pattern approach.

---

## Type Error Categories

After all codemod transforms run, `mig-manual` is the branch for manual fixes. Every
category below is **idempotent** -- running the fix on already-fixed code is a no-op.
Subagents must attempt EVERY error. If no heuristic matches, report as UNCATEGORIZED.

### Category 1: Legacy COB API (subagent)

**Error:** `undefined-field: SetUnitCOBValue` or `GetUnitCOBValue`

**Fix:** Replace with the gadget-facing COB API:
```lua
-- Before
Spring.SetUnitCOBValue(unitID, COB.ACTIVATION, 0)
-- After
SpringSynced.UnitScript.SetUnitCOBValue(unitID, COB.ACTIVATION, 0)
```
**WARNING:** Use `SetUnitCOBValue`/`GetUnitCOBValue` (3-arg, takes unitID), NOT
`SetUnitValue`/`GetUnitValue` (2-arg unitscript-internal, no unitID).

### Category 2: Nonexistent Engine API (subagent)

**Error:** `undefined-field: GetProjectileName`

**Fix:** Replace with `SpringShared.GetProjectileDefID`.

### Category 3: Method Name Typo (subagent)

**Error:** `undefined-field: Spring.GameFrame`

**Fix:** `SpringShared.GetGameFrame()`.

### Category 4: Wrong Table (subagent)

**Error:** `undefined-field: Spring.ZlibCompress`

**Fix:** `VFS.ZlibCompress` / `VFS.ZlibDecompress` (note capitalization fix).

### Category 5: UnitScript Sub-table (orchestrator)

Engine annotation + `just lua::library` fix. Subagents assume this is already done.

### Category 6: UnitRendering / FeatureRendering (orchestrator)

Engine annotation + `just lua::library` fix. Subagents assume this is already done.

### Category 7: Engine Constants (orchestrator)

Already resolved by engine annotations. No action needed.

### Category 8: GameCMD Type Stub (orchestrator)

Ensure `types/GameCMD.lua` exists and `"GameCMD"` is in `.luarc.json` globals.

### Category 9: Game.Commands / Game.CustomCommands (orchestrator)

Ensure `types/Game.lua` extends the `Game` class with these fields.

### Category 10: Sandbox Globals (orchestrator)

Ensure ALL engine/sandbox/BAR globals are in `.luarc.json` `diagnostics.globals`. Full list:

**UnitScript:** `Turn`, `Move`, `Spin`, `StopSpin`, `WaitForTurn`, `WaitForMove`, `Hide`,
`Show`, `Explode`, `EmitSfx`, `StartThread`, `SetSignalMask`, `Signal`, `Sleep`,
`GetUnitValue`, `SetUnitValue`, `piece`, `script`, `UnitScript`, `x_axis`, `y_axis`,
`z_axis`, `SIG_WALK`, `UNITSCRIPT_DIR`

**Engine/sandbox:** `widgetHandler`, `gadgetHandler`, `Commands`, `fontHandler`,
`LUAUI_DIRNAME`, `socket`, `pairsByKeys`, `SendToUnsynced`, `CallAsTeam`, `handler`,
`lowerkeys`, `addon`, `gcinfo`, `loadlib`

**BAR-specific:** `GameCMD`, `Scenario`, `game_engine`, `SG`, `CMD_AREA_MEX`,
`CMD_WANT_CLOAK`, `CMD_WANTED_SPEED`, `UpdateGuishaderBlur`, `GadgetCrashingAircraft`,
`CALLIN_MAP`, `CommandNames`, `ExplosionDefs`

**Test framework:** `describe`, `it`, `spec`, `before_each`

### Category 11: Stale Manual Stubs (subagent)

**Error:** `duplicate-doc-field` or conflicting types from `types/Spring.lua`

**Fix:** If `types/Spring.lua` contains `---@class SpringSynced` with `@field` entries for
engine methods (GetModOptions, GetGameFrame, etc.), remove that entire block. Keep only
BAR-side extensions (UnitScriptTable, ObjectRenderingTable) and temporary data types
(ResourceData, TeamData, PlayerData, UnitWrapper).

### Category 12: I18N Type (subagent)

**Fix:** Ensure `types/I18N.lua` contains the `I18NModule` class definition (callable table
with `translate`, `load`, `set`, `setLocale`, `getLocale`, `loadFile`, `unitName`,
`setLanguage`, `languages` fields plus `@overload fun(key, data?): string`).

### Category 13: Undefined Variables / Actual Bugs (subagent)

**Error:** `undefined-global` for lowercase variable names (`alpha`, `lastframeduration`)

**Fix:** Declare `local varName = defaultValue` in the same lexical scope to preserve
the semantic name. Examples:
```lua
-- Before: alpha used but never defined
uniformFloat = { shaderparams = { alpha, 0.5, 0.5, 0.5 } }
-- After: preserve the name, provide the default
local alpha = 0
uniformFloat = { shaderparams = { alpha, 0.5, 0.5, 0.5 } }
```
For scoping bugs, hoist the `local` declaration before the block.

### Category 14: Forward-Compat API Guards (subagent)

**Pattern:** `if not Spring.GetAvailableControllers then return end`

**Fix:** Comment out the guard and guarded block:
```lua
-- forward-compat: API not yet available
-- if not Spring.GetAvailableControllers then return end
```

### Category 15: Commented-Out Spring. References

LuaLS ignores comments. No action needed. Not a type error.

### Category 16: GL4 Object Methods -- VBO/VAO/Shader (subagent)

**Error:** `undefined-field: Delete` / `Upload` / `DrawArrays` / `SetUniform` / etc.

**Fix:** Find where the object is created and add a type annotation on the line before:
```lua
---@type VBO
local myVBO = gl.GetVBO(GL.ARRAY_BUFFER, true)

---@type VAO
local myVAO = gl.GetVAO()

---@type Shader
local myShader = gl.CreateShader({ ... })
```
If the object is stored in a table field, annotate the assignment:
```lua
---@type VBO
self.vbo = gl.GetVBO(GL.ARRAY_BUFFER, true)
```
If the object comes from `makeInstanceVBOTable()`, annotate with `---@type InstanceVBOTable`.

### Category 17: Remaining Undefined Globals (subagent)

**Error:** `undefined-global` for piece names (`lloarm`, `rloarm`) in LUS scripts.

**Fix:** Report as UNCATEGORIZED. These are LUS piece environment globals that the
engine injects per-script.

### Category 18: Dead `if not Spring` Guards (subagent)

**Fix:** Delete the guard. If needed, replace with `if not SpringShared then return end`.

### Category 19: Erroneous `self` References (subagent)

**Fix:** Replace `self.X` with `ModuleName.X` where the file is a module, not a class.

### Category 20: Font Object Methods (subagent)

**Error:** `undefined-field: Print` / `Begin` / `End` / `SetTextColor` / etc.

**Fix:** Add `---@type LuaFont` on the line before the `gl.LoadFont()` assignment:
```lua
---@type LuaFont
local font = gl.LoadFont(fontfile, fontSize, outlineWidth, outlineWeight)
```

### Category 21: Engine Optional Params (orchestrator)

Engine-side fix. Subagents assume stubs are correct. If a `nil → number` error persists
on an engine API call, the subagent should add `or 0` as a default.

### Category 22: MoveType / UnitDef Missing Fields (orchestrator + subagent)

**Orchestrator:** Create `types/MoveTypeData.lua` with specific `@field` entries for
`name`, `maxReverseSpeed`, `aircraftState`, etc.

**Subagent:** If `GetUnitMoveTypeData()` result is used and fields are undefined, add
`---@type table` on the variable. Report the specific missing field as UNCATEGORIZED so
orchestrator can add it to the type stub.

### Category 23: Command Queue `tag` Field (orchestrator)

Ensure `types/Extensions.lua` has `---@class Command` with `@field tag integer?` and
`@field [string] any`.

### Category 24: Engine Math Extensions (subagent)

**Error:** `undefined-field: fract` on `math`

**Fix:** Replace `math.fract(x)` with `(x - math.floor(x))`. The engine does not expose
`math.fract` as a registered Lua function.

### Category 25: Callin Missing Arguments (subagent)

**Error:** `missing-parameter` on callin bootstrap in `Initialize`

**Fix:** Pass full args:
- `UnitCreated(unitID, unitDefID, teamID, builderID?)` -- pass `SpringShared.GetUnitTeam(unitID)`
- `PlayerChanged(playerID)` -- pass `SpringUnsynced.GetLocalPlayerID()`
- `FeatureCreated(featureID, allyTeam)` -- pass `SpringShared.GetFeatureAllyTeam(fID)`
- `ViewResize(viewSizeX, viewSizeY)` -- pass `SpringUnsynced.GetViewGeometry()`
- `UnitDestroyed(unitID, unitDefID, unitTeam)` -- pass all 3

### Category 26: Nilable Returns Passed to Required Params (subagent)

**Error:** `Cannot assign number? to parameter number`

**Fix:** Add `--[[@as number]]` cast, or `or 0` if used in arithmetic. Do NOT leave
unfixed -- at minimum apply the cast.
```lua
-- Before
AreTeamsAllied(GetUnitTeam(unitID), myTeam)
-- After (cast)
AreTeamsAllied(GetUnitTeam(unitID) --[[@as integer]], myTeam)
-- After (default, preferred if in arithmetic)
local team = GetUnitTeam(unitID) or 0
```

### Category 27: `string` vs `stringlib` (subagent)

**Error:** `string cannot match stringlib`

**Fix:** Add `---@diagnostic disable-next-line: param-type-mismatch` on the affected line.
This is a known LuaLS limitation with Lua's string metatable.

### Category 28: Duplicate Table Keys (subagent)

**Error:** `Duplicate index X`

**Fix:** Remove the duplicate key (keep the last one, which is what Lua uses).

### Category 29: Busted/Luassert Test Framework

Known gap. Leave for now. Test intellisense is a separate workstream.

### Category 30: Duplicate `@class` Blocks (subagent)

**Error:** `duplicate-doc-field`

**Fix:** Consolidate to a single `@class` definition per type. Keep one file per class
in `types/` (e.g., `types/Command.lua`). Do NOT create monolithic `types/Extensions.lua`
with multiple classes -- use one file per class.

### Category 31: Missing `addon` Global (subagent)

**Fix (idempotent):** Ensure `types/Addon.lua` contains:
```lua
---@type Addon
---@diagnostic disable-next-line: lowercase-global
addon = nil
```
If `"addon"` is not in `.luarc.json` globals, report as UNCATEGORIZED for orchestrator.

### Category 32: SetGameRulesParam with Boolean (subagent)

**Error:** `Cannot assign boolean to parameter (string|number)?`

**Fix:** The engine accepts booleans. If stubs are already fixed, this resolves. If not,
convert to integer: `SetGameRulesParam(name, value and 1 or 0)`. Report as UNCATEGORIZED
if the stub still rejects boolean after engine fixes.

### Category 33: GetGameRulesParam Default Arg (subagent)

**Error:** `redundant-parameter` on `GetGameRulesParam(name, 0)`

**Fix:** The engine only accepts 1 arg. Move the default to `or`:
```lua
-- Before
local val = GetGameRulesParam("key", 0)
-- After
local val = GetGameRulesParam("key") or 0
```

### Category 34: Callin Routing Extra Args (orchestrator)

**Error:** `redundant-parameter` on `widget:UnitCreated(..., nil, "UnitFinished")`

BAR passes extra string args through callins for internal routing. Lua silently ignores them.

**Fix (orchestrator):** Extend callin types in `types/Callins.lua` to accept `...: any`:
```lua
---@class Callins
---@field UnitCreated fun(self, unitID: integer, unitDefID: integer, unitTeam: integer, builderID: integer?, ...: any)?
---@field UnitDestroyed fun(self, unitID: integer, unitDefID: integer, unitTeam: integer, attackerID: integer?, attackerDefID: integer?, attackerTeam: integer?, weaponDefID: integer?, ...: any)?
---@field GameFrame fun(self, frame: integer, ...: any)?
```

### Category 35: `need-check-nil` (subagent)

**Error:** `Need check nil.`

**Strategy -- apply the FIRST matching rule:**

1. **Table/method access on nil** (`x[field]`, `x.field`, `x:method()` where `x` is `T?`):
   Add `if not x then return end` before the access. SAFE in widget callins (DrawScreen,
   DrawWorld, Update, GameFrame) where returning early just skips a frame.

2. **Nil in arithmetic** (`x + 1` where `x` is `number?`):
   Replace with `(x or 0) + 1`.

3. **Nil passed to function** (`fn(x)` where `x` is `T?`):
   Replace with `fn(x or default)` -- `0` for numbers, `""` for strings, `{}` for tables.

4. **Nested table access** (`tbl[a][b]` where `tbl[a]` might be nil):
   Add `if not tbl[a] then return end` or use `tbl[a] and tbl[a][b]`.

5. **In `Initialize` / `Shutdown` / game-logic functions**: Do NOT add `return` guards
   (would break state). Instead add `or default` or `--[[@as Type]]` cast. Flag in output
   as `ATTEMPTED (need-check-nil in game logic)` for orchestrator review.

### Category 36: `cast-local-type` (subagent)

**Error:** `This variable is defined as type X. Cannot convert its type to Y.`

**Fix:** Add `---@type X|Y` before the variable declaration, or `---@type Y` before the
reassignment line:
```lua
---@type integer?
local checkQueueTime = 0
-- ... later ...
checkQueueTime = nil  -- no longer errors
```

### Category 37: `assign-type-mismatch` (subagent)

**Error:** `Cannot assign X to Y.`

**Fix:** Add `--[[@as Y]]` cast on the right-hand side:
```lua
local widget = widget --[[@as Widget]]
```

### Cast Syntax Rules (CRITICAL for subagents)

**NEVER put array types inside `--[[@as ...]]` block comments.** The first `]` in
`integer[]` (or `Foo[]`) **closes the long comment**, leaving trailing `]` as code
and producing `unknown-symbol` / parse errors.

```lua
-- WRONG (comment ends at first ])
local xs = f() --[[@as integer[]]]

-- RIGHT: cast the local on the next line
local xs = f()
---@cast xs integer[]

-- RIGHT: alias without brackets inside the block comment
---@alias IntegerArray integer[]
local xs = f() --[[@as IntegerArray]]
```

**`---@cast`** only works on LOCAL VARIABLES, never on table fields:
```lua
-- CORRECT
---@cast myVar VBO
myVar:Delete()

-- WRONG (causes unknown-cast-variable error)
---@cast tbl.field VBO
tbl.field:Delete()
```

For table fields, extract to a local variable (preferred):
```lua
local v = tbl.field
if v then v:Delete() end
```

**NEVER** use `--[[@as Type]]` at the end of a line if the NEXT line starts with `(`.
Lua 5.1 treats `)\n(` as a function call chain, causing `ambiguous-syntax` errors.
If you must use inline casts on table field access, put a semicolon before the next line:
```lua
local x = tbl.field --[[@as VBO]]
;(otherTbl.vao):DrawArrays(...)  -- semicolon prevents ambiguity
```

### Type File Hygiene (CRITICAL for subagents)

- Do NOT create `types/` files that duplicate classes already defined in
  `recoil-lua-library/library/generated/*.lua` or `modules/graphics/instancevbotable.lua`.
  LuaLS merges class definitions and duplicates cause `duplicate-doc-field` errors.
- Check if a class already exists before creating a new type file for it.
- Classes already defined elsewhere: `VBO`, `VAO`, `Shader`, `LuaFont`,
  `InstanceVBOTable`, `Callins`, `Widget`, `Gadget`, `Addon`.

**NEVER declare `---@class Widget` / `---@class VAO` / `---@class VBO` inside
`luaui/Widgets/*.lua` (or gadget files).** EmmyLua merges `@class` across the whole
workspace; a widget-local “patch” overwrites or conflicts with `types/Widget.lua` and
engine stubs, causing cascading `assign-type-mismatch` / `duplicate-doc-field` in other
files. Use only:

```lua
local widget ---@type Widget = widget
```

and add rare missing callins on the orchestrator side in `types/Widget.lua` if truly needed.

### Category 38: `Shader` vs BAR `gl.LuaShader` objects (subagent)

**Error:** `undefined-field: SetUniform` / `Activate` / `SetUniformInt` on a value typed
as `Shader`.

**Cause:** `types/Shader.lua` defines `---@alias Shader integer` (OpenGL program ID).
BAR’s `gl.LuaShader({ ... })` return value is **not** that integer; it is a userdata
shader object.

**Fix:** Annotate as `---@type BarLuaShader?` (or non-optional when known initialized).
Add missing method stubs to `types/BarLuaShader.lua` if LuaLS still complains.

---

## Structural Type Fixes (orchestrator reference)

These are applied by the orchestrator before subagent runs. Subagents assume they exist.

### GL Type Alias
`types/GL.lua`: `---@alias GL integer`

### Widget/Gadget/Addon Open Types
`types/Widget.lua`, `types/Gadget.lua`, `types/Addon.lua`: `---@field [string] any`

### Engine Shader Params
`LuaShaders.cpp`: `@param shaderID Shader|integer` on all shader functions.

### Engine Optional Params
Many engine APIs have `luaL_opt*` for optional params. The orchestrator adds `?` to
`@param` annotations in engine C++ and regenerates via `just lua::library`.

### Engine Missing Function Annotations
Some engine functions lack `@function` doc blocks. The orchestrator adds them and
regenerates. Example: `gl.LoadFont` was missing, now annotated with `@return LuaFont`.

### duplicate-set-field
Disabled project-wide in `.luarc.json` via `diagnostics.disable: ["duplicate-set-field"]`.

### Cascade Warning
Adding type annotations can INCREASE error counts (LuaLS strict-checks downstream usage).
Accept this as the cost of true type safety. Prefer non-optional returns for functions
that rarely fail (fonts, VBOs).

---

## Diagnostic Reference for `types/` Stubs

| File | Defines | Source of truth |
|------|---------|-----------------|
| `types/Spring.lua` | BAR-side `UnitScriptTable`/`ObjectRenderingTable` extensions, temp data classes | `unit_script.lua`, `unitrendering.lua` |
| `types/GameCMD.lua` | `GameCMD` class | `modules/customcommands.lua` |
| `types/Game.lua` | `Game.Commands`, `Game.CustomCommands` | `init.lua` + `modules/commands.lua` |
| `types/I18N.lua` | `I18NModule` | `modules/i18n/i18n.lua` (kikito) |
| `types/Utilities.lua` | `Utilities` class | `common/springFunctions.lua` |
| `types/Debug.lua` | `BARDebug` class | `common/springUtilities/debug.lua` |
| `types/Lava.lua` | `Lava` class | `modules/lava.lua` |
| `types/GetModOptionsCopy.lua` | `GetModOptionsCopy` function | `common/springOverrides.lua` |
| `types/Gadget.lua` | `Gadget`, `gadget`, `GG` | Engine gadget handler |
| `types/Widget.lua` | `Widget`, `widget`, `WG` | Engine widget handler |
| `types/Addon.lua` | `Addon`, `AddonInfo`, `addon` | Engine addon base |
| `types/GL.lua` | `GL` alias to `integer` | Engine GL constants |
| `types/Extensions.lua` | `Command`, `Blueprint`, `RmlUi.ElementPtr`, etc. | Runtime extensions |
| `types/Callins.lua` | Callin overrides with `...: any` for routing args | Engine callin stubs |

Subagents may CREATE new `types/ClassName.lua` files for classes they need to extend.
Use `---@meta` header. One class per file.
