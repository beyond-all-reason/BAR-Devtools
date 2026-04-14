---
name: bar-codemod-prereq
description: >-
  Categorize and fix LuaLS type errors in the Beyond-All-Reason Lua codebase.
  Each category maps an `emmylua_check` error pattern to an idempotent fix
  recipe. Used as the rule reference for `scripts/codemod/llm-type-triage.sh` workers
  applying per-file annotation fixes after the deterministic codemod transforms.
---

# BAR Type Error Categories

This document is a categorization rulebook for BAR's Lua type errors. Each
category pairs an `emmylua_check` error pattern with an idempotent fix recipe.
Run the pattern matchers in priority order (1 → 42); the first match wins.

## What this is for

`scripts/codemod/llm-type-triage.sh` dispatches parallel `claude --print` workers, one
per chunk of errors. Each worker uses this document to match its assigned
errors to a category and apply the fix in-place. Single pass — if a category
fails to shrink after one run, that's a signal the rules need a new entry,
not "let the LLM try again".

## What to do when no category matches

Some errors are not fixable by a per-file annotation edit — they require a
new type stub in `types/`, an `.emmyrc.json` global, an engine C++ change,
or a `recoil-lua-library` regeneration. These fixes belong to the env layer
(`fmt-llm-source` branch) and are out of scope for per-file workers.

**If no category below matches your error**, report it as `UNCATEGORIZED` in
your output with the exact error message and surrounding context. A human
will either add a new category to this document or apply the env-layer fix.
Categories below that say *"already fixed by the env layer"* are cross-references
so you recognize the pattern and don't try to fix it yourself — flag and move on.

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

Every category below is **idempotent** — running the fix on already-fixed code
is a no-op. Attempt every error in your chunk. If no heuristic matches, report
the error as UNCATEGORIZED with the exact message and surrounding context.

### Category 1: Legacy COB API
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

### Category 2: Nonexistent Engine API
**Error:** `undefined-field: GetProjectileName`

**Fix:** Replace with `SpringShared.GetProjectileDefID`.

### Category 3: Method Name Typo
**Error:** `undefined-field: Spring.GameFrame`

**Fix:** `SpringShared.GetGameFrame()`.

### Category 4: Wrong Table
**Error:** `undefined-field: Spring.ZlibCompress`

**Fix:** `VFS.ZlibCompress` / `VFS.ZlibDecompress` (note capitalization fix).

### Category 5: UnitScript Sub-table — env-layer reference, flag as UNCATEGORIZED if seen

Engine annotation + `just lua::library` fix. Subagents assume this is already done.

### Category 6: UnitRendering / FeatureRendering — env-layer reference, flag as UNCATEGORIZED if seen

Engine annotation + `just lua::library` fix. Subagents assume this is already done.

### Category 7: Engine Constants — env-layer reference, flag as UNCATEGORIZED if seen

Already resolved by engine annotations. No action needed.

### Category 8: GameCMD Type Stub — env-layer reference, flag as UNCATEGORIZED if seen

Ensure `types/GameCMD.lua` exists and `"GameCMD"` is in `.luarc.json` globals.

### Category 9: Game.Commands / Game.CustomCommands — env-layer reference, flag as UNCATEGORIZED if seen

Ensure `types/Game.lua` extends the `Game` class with these fields.

### Category 10: Sandbox Globals — env-layer reference, flag as UNCATEGORIZED if seen

Ensure ALL engine/sandbox/BAR globals are in `.emmyrc.json` `diagnostics.globals`
(EmmyLua's analyzer is the source of truth for `just bar::check`; `.luarc.json`
holds lux library paths and is consumed by the sumneko LSP for IDE use). EmmyLua
treats `undefined-global` as an **error** (not a warning like sumneko did), so a
missing global multiplies the error count by 10–100x. Full list:

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

### Category 11: Stale Manual Stubs
**Error:** `duplicate-doc-field` or conflicting types from `types/Spring.lua`

**Fix:** If `types/Spring.lua` contains `---@class SpringSynced` with `@field` entries for
engine methods (GetModOptions, GetGameFrame, etc.), remove that entire block. Keep only
BAR-side extensions (UnitScriptTable, ObjectRenderingTable) and temporary data types
(ResourceData, TeamData, PlayerData, UnitWrapper).

### Category 12: I18N Type
**Fix:** Ensure `types/I18N.lua` contains the `I18NModule` class definition (callable table
with `translate`, `load`, `set`, `setLocale`, `getLocale`, `loadFile`, `unitName`,
`setLanguage`, `languages` fields plus `@overload fun(key, data?): string`).

### Category 13: Undefined Variables / Actual Bugs
**Error:** `undefined-global` for lowercase variable names (`alpha`, `lastframeduration`)

**Important:** Match this category ONLY after Cat 43 (`X = X` self-shadow)
and Cat 45 (unit script piece names) have been ruled out — those have
mechanical fixes that don't require declaring a new local.

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

**Sub-pattern — destructured assignment self-reference:**

```lua
-- WRONG (pieceAngle is the LHS being assigned, but used on the RHS)
local _, pieceAngle = spCallCOBScript(ownerID, "DroneDocked", 5, pieceAngle, droneMetaData.dockingPiece)
```

This is a real bug — `pieceAngle` on the RHS resolves to the global
(nil), not the local being created on the LHS. Either the developer
meant to thread an outer-scope `pieceAngle` through (in which case
declare `local pieceAngle = nil` in the enclosing block above the loop)
or the call signature genuinely doesn't need that argument (drop it).
When in doubt, declare `local pieceAngle = nil` in the enclosing block
above the first reference — preserves semantics, kills the error.

**Sub-pattern — typo (e.g. `subunitDef` vs `subUnitDef`):**

```lua
local subUnitDef = UnitDefNames[dronename]
if subunitDef then  -- typo: lowercase 'u'
    metalCost = subUnitDef.metalCost
```

Fix the typo. This is the only category where a worker is allowed to
make a small change to a referenced identifier (vs. only adding
declarations/annotations) — but only when the intended name is
unambiguously visible in the same function scope.

### Category 14: Forward-Compat API Guards
**Pattern:** `if not Spring.GetAvailableControllers then return end`

**Fix:** Comment out the guard and guarded block:
```lua
-- forward-compat: API not yet available
-- if not Spring.GetAvailableControllers then return end
```

### Category 15: Commented-Out Spring. References

LuaLS ignores comments. No action needed. Not a type error.

### Category 16: GL4 Object Methods -- VBO/VAO/Shader
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

### Category 17: Remaining Undefined Globals
**Error:** `undefined-global` for piece names (`lloarm`, `rloarm`) in LUS scripts.

**Fix:** Report as UNCATEGORIZED. These are LUS piece environment globals that the
engine injects per-script.

### Category 18: Dead `if not Spring` Guards
**Fix:** Delete the guard. If needed, replace with `if not SpringShared then return end`.

### Category 19: Erroneous `self` References
**Fix:** Replace `self.X` with `ModuleName.X` where the file is a module, not a class.

### Category 20: Font Object Methods
**Error:** `undefined-field: Print` / `Begin` / `End` / `SetTextColor` / etc.

**Fix:** Add `---@type LuaFont` on the line before the `gl.LoadFont()` assignment:
```lua
---@type LuaFont
local font = gl.LoadFont(fontfile, fontSize, outlineWidth, outlineWeight)
```

### Category 21: Engine Optional Params — env-layer reference, flag as UNCATEGORIZED if seen

Already handled by env-layer engine annotations. If a `nil → number` error
still persists on an engine API call, apply the worker workaround: add `or 0`
as a default at the call site.

### Category 22: MoveType / UnitDef Missing Fields

If `GetUnitMoveTypeData()` result is used and fields are undefined, add
`---@type table` on the variable as a workaround. Report the specific
missing field as UNCATEGORIZED so a maintainer can extend the type stub
in `types/MoveTypeData.lua` (env-layer fix).

### Category 23: Command Queue `tag` Field — env-layer reference, flag as UNCATEGORIZED if seen

Ensure `types/Extensions.lua` has `---@class Command` with `@field tag integer?` and
`@field [string] any`.

### Category 24: Engine Math Extensions
**Error:** `undefined-field: fract` on `math`

**Fix:** Replace `math.fract(x)` with `(x - math.floor(x))`. The engine does not expose
`math.fract` as a registered Lua function.

### Category 25: Callin Missing Arguments
**Error:** `missing-parameter` on callin bootstrap in `Initialize`

**Fix:** Pass full args:
- `UnitCreated(unitID, unitDefID, teamID, builderID?)` -- pass `SpringShared.GetUnitTeam(unitID)`
- `PlayerChanged(playerID)` -- pass `SpringUnsynced.GetLocalPlayerID()`
- `FeatureCreated(featureID, allyTeam)` -- pass `SpringShared.GetFeatureAllyTeam(fID)`
- `ViewResize(viewSizeX, viewSizeY)` -- pass `SpringUnsynced.GetViewGeometry()`
- `UnitDestroyed(unitID, unitDefID, unitTeam)` -- pass all 3

### Category 26: Nilable Returns Passed to Required Params
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

### Category 27: `string` vs `stringlib`
**Error:** `string cannot match stringlib`

**Fix:** Add `---@diagnostic disable-next-line: param-type-mismatch` on the affected line.
This is a known LuaLS limitation with Lua's string metatable.

### Category 28: Duplicate Table Keys
**Error:** `Duplicate index X`

**Fix:** Remove the duplicate key (keep the last one, which is what Lua uses).

### Category 29: Busted/Luassert Test Framework

Known gap. Leave for now. Test intellisense is a separate workstream.

### Category 30: Duplicate `@class` Blocks
**Error:** `duplicate-doc-field`

**Fix:** Consolidate to a single `@class` definition per type. Keep one file per class
in `types/` (e.g., `types/Command.lua`). Do NOT create monolithic `types/Extensions.lua`
with multiple classes -- use one file per class.

### Category 31: Missing `addon` Global
**Fix (idempotent):** Ensure `types/Addon.lua` contains:
```lua
---@type Addon
---@diagnostic disable-next-line: lowercase-global
addon = nil
```
If `"addon"` is not in `.emmyrc.json` globals, report as UNCATEGORIZED — env-layer fix.

### Category 32: SetGameRulesParam with Boolean
**Error:** `Cannot assign boolean to parameter (string|number)?`

**Fix:** The engine accepts booleans. If stubs are already fixed, this resolves. If not,
convert to integer: `SetGameRulesParam(name, value and 1 or 0)`. Report as UNCATEGORIZED
if the stub still rejects boolean after engine fixes.

### Category 33: GetGameRulesParam Default Arg
**Error:** `redundant-parameter` on `GetGameRulesParam(name, 0)`

**Fix:** The engine only accepts 1 arg. Move the default to `or`:
```lua
-- Before
local val = GetGameRulesParam("key", 0)
-- After
local val = GetGameRulesParam("key") or 0
```

### Category 34: Callin Routing Extra Args — env-layer reference, flag as UNCATEGORIZED if seen

**Error:** `redundant-parameter` on `widget:UnitCreated(..., nil, "UnitFinished")`

BAR passes extra string args through callins for internal routing. Lua silently ignores them.

**Fix (env-layer):** Extend callin types in `types/Callins.lua` to accept `...: any`:
```lua
---@class Callins
---@field UnitCreated fun(self, unitID: integer, unitDefID: integer, unitTeam: integer, builderID: integer?, ...: any)?
---@field UnitDestroyed fun(self, unitID: integer, unitDefID: integer, unitTeam: integer, attackerID: integer?, attackerDefID: integer?, attackerTeam: integer?, weaponDefID: integer?, ...: any)?
---@field GameFrame fun(self, frame: integer, ...: any)?
```

### Category 35: `need-check-nil`
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
   as `ATTEMPTED (need-check-nil in game logic)` for human review.

### Category 36: `cast-local-type`
**Error:** `This variable is defined as type X. Cannot convert its type to Y.`

**Fix:** Add `---@type X|Y` before the variable declaration, or `---@type Y` before the
reassignment line:
```lua
---@type integer?
local checkQueueTime = 0
-- ... later ...
checkQueueTime = nil  -- no longer errors
```

### Category 37: `assign-type-mismatch`
**Error:** `Cannot assign X to Y.`

**Fix:** Add `--[[@as Y]]` cast on the right-hand side:
```lua
local widget = widget --[[@as Widget]]
```

### Cast Syntax Rules (CRITICAL)

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

### Type File Hygiene (CRITICAL)

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

If a callin is truly missing, flag UNCATEGORIZED so a maintainer can extend
`types/Widget.lua` (env-layer fix).

### Category 38: `Shader` vs BAR `gl.LuaShader` objects
**Error:** `undefined-field: SetUniform` / `Activate` / `SetUniformInt` on a value typed
as `Shader`.

**Cause:** `types/Shader.lua` defines `---@alias Shader integer` (OpenGL program ID).
BAR’s `gl.LuaShader({ ... })` return value is **not** that integer; it is a userdata
shader object.

**Fix:** Annotate as `---@type BarLuaShader?` (or non-optional when known initialized).
Add missing method stubs to `types/BarLuaShader.lua` if LuaLS still complains.

### Category 39: `---@type X <prose>` description after type
**Error:** `doc-syntax-error: expect type` / `binary operator not followed by type`

**Cause:** EmmyLua parses everything after `---@type` as a type expression. Bare prose
words like `in seconds` are parsed as type tokens (`in` is reserved as a binary
type operator) and produce parse errors.

**Fix:** Use the `#` description delimiter or move the prose to a separate comment line.

```lua
-- WRONG (prose collides with type parser)
local doubleClickTime = 0.2 ---@type number in seconds
---@type integer in pixels, as the Manhattan norm
local dist = 12

-- RIGHT (# delimiter)
local doubleClickTime = 0.2 ---@type number # in seconds
---@type integer # in pixels, as the Manhattan norm
local dist = 12
```

The `#` form is supported by LuaLS, EmmyLua, and `lua-language-server`.

### Category 40: `---@field X T [interval]` bracket prose in field doc
**Error:** `syntax-error: expected TkRightBracket, but get TkComma`

**Cause:** `---@field name T <description>` allows trailing prose, but a leading `[`
is parsed as the start of `T[]` array syntax. `integer [0, 1e6) ...` is parsed as
`integer[`, then `0`, then expects `]` but finds `,`.

**Fix:** Wrap interval notation in backticks AFTER the prose, or push it to the end.

```lua
-- WRONG (leading bracket parsed as array)
---@field crushstrength integer [0, 1e6) mass equivalent for crushing

-- RIGHT (backticked, at end)
---@field crushstrength integer mass equivalent for crushing, in `[0, 1e6)`
```

### Category 41: `---@type FuncType` on `local function` declaration
**Error:** `annotation-usage-error: ` `` `@type X` can't be used here ``

**Cause:** EmmyLua only allows `---@type` on variable assignments, not on
`local function name(...)` declarations.

**Fix:** Convert to `local name = function(...)` form.

```lua
-- WRONG
---@type ShieldPreDamagedCallback
local function shieldPreDamaged(projectileID, ...) end

-- RIGHT
---@type ShieldPreDamagedCallback
local shieldPreDamaged = function(projectileID, ...) end
```

Alternative (preferred when callback is exported): annotate the function with
`---@param`/`---@return` directly instead of using a callback type alias.

### Category 42: Misplaced `---@return` or `---@param`
**Error:** `annotation-usage-error: ` `` `@return X` can't be used here ``

**Cause:** `---@return` / `---@param` annotations belong immediately above a
function declaration, not above an unrelated `local x = ...` line.

**Fix:** Move the annotation block to the line directly above the actual function
it documents.

```lua
-- WRONG (comment binds to wrong declaration)
---@return number
local currentBlueprintUnitID = 0
local function nextBlueprintUnitID() ... end

-- RIGHT (comment binds to the function)
local currentBlueprintUnitID = 0
---@return number
local function nextBlueprintUnitID() ... end
```

### Category 43: `X = X` same-name self-shadow (idiomatic global capture)

**Error:** `undefined global variable: X` on a line where `X` appears on
both sides of `=` with the same name. Three sub-patterns:

1. **Local capture** — `local X = X` or `local X = X or <default>`
2. **Table-export field** — `X = X,` or `X = X or {},` inside a
   `{ ... }` literal (typically a `return { ... }` module export or
   `WG.Module = { ... }` widget API table)
3. **Plain reassign** — `X = X` (rare, but the same fix applies)

**Cause:** The `X = X` pattern intentionally references a same-named
global — for performance (`local pairs = pairs`), for capturing optional
config globals (`local logRAM = logRAM`, `local noRushTime = noRushTime
or 0`), or for re-exporting a private upvalue under the same public name
in a module-export table (`return { customPresets = customPresets or {}
}`). The right-hand `X` is the global, which the analyzer can't see.
Adding `X` to `.emmyrc.json` is heavy-handed when the global is
file-scoped or rarely set.

**Fix:** Insert a `disable-next-line` comment immediately above the line.
Idempotent (runs as a no-op if the comment is already there).

```lua
-- WRONG (analyzer can't see the right-hand X)
local running = running
local logRAM = logRAM
local noRushTime = noRushTime or 0

return {
    customPresets = customPresets or {},
    uploadElementRange = uploadElementRange,
}

-- RIGHT
---@diagnostic disable-next-line: undefined-global
local running = running
---@diagnostic disable-next-line: undefined-global
local logRAM = logRAM
---@diagnostic disable-next-line: undefined-global
local noRushTime = noRushTime or 0

return {
    ---@diagnostic disable-next-line: undefined-global
    customPresets = customPresets or {},
    ---@diagnostic disable-next-line: undefined-global
    uploadElementRange = uploadElementRange,
}
```

**Sibling pattern — defensive `X and X() or default` cross-file reference:**

```lua
-- WRONG (GetAliveTeammates is in another file the analyzer can't see)
local teammates = GetAliveTeammates and GetAliveTeammates() or {}

-- RIGHT
---@diagnostic disable-next-line: undefined-global
local teammates = GetAliveTeammates and GetAliveTeammates() or {}
```

This isn't strictly a self-shadow, but the fix is identical: a single
`disable-next-line` above the call site. The `X and X()` guard already
proves the developer knows `X` may not exist.

**Do NOT** convert these to `local running = _G.running` — that loses
the `or default` ergonomics and is harder to read. The disable comment
is the canonical fix.

**Do NOT** stack disable-next-line comments at the top of the file
hoping they'll cover later lines — `disable-next-line` only affects the
**single line directly below** the comment. If a file has many such
captures, put one disable above each one.

### Category 44: `---@param`/`---@return` on a function re-export site

**Error:** `` `@param X T` can't be used here `` /
`` `@return X` can't be used here `` on a line of the form
`<name> = <function-reference>` — either inside a table literal
(`WG.Module = { foo = foo, }`) or as a direct field assignment
(`table.toString = tableToString`).

**Cause:** The `@param`/`@return` annotations are attached to the
**re-export** of an upvalue function reference, not to the actual
function definition. EmmyLua only accepts these annotations directly
above a `function` declaration, never above an assignment that merely
stores a function reference under a different name. The annotations
are valuable (they document the real signature), they're just in the
wrong location.

**Fix:** **Move** the `@param`/`@return` block from the re-export site
to the line directly above the actual `local function <name>(...)` (or
`<name> = function(...)`) definition for that upvalue. The leading
prose `---` description lines should also move with them. Find the
function definition by searching for `function <name>` in the same file.

Idempotent: re-running this fix on already-relocated annotations is a
no-op (the analyzer is happy, no error to match against).

```lua
-- WRONG: annotations live on the re-export, not the function

-- 1. Inside a table literal
local function addSpotlight(objectType, owner, objectID, color, options)
    -- ... body ...
end

WG.ObjectSpotlight = {
    --- Adds a new spotlight for a given object.
    --- @param objectType string "unit", "feature", or "ground"
    --- @param owner string An identifier...
    --- @param objectID number|number[] unitID, featureID, ...
    --- @return nil
    addSpotlight = addSpotlight,
}

-- 2. Direct field assignment
local function tableToString(tbl, options, _seen, _depth) end
-- ... body ...

---Recursively turns a table into a string, suitable for printing.
---@param tbl table
---@param options table Optional parameters
---@return string
table.toString = tableToString


-- RIGHT: annotations live above the function definition

-- 1. Inside a table literal — moved to local function
--- Adds a new spotlight for a given object.
--- @param objectType string "unit", "feature", or "ground"
--- @param owner string An identifier...
--- @param objectID number|number[] unitID, featureID, ...
--- @return nil
local function addSpotlight(objectType, owner, objectID, color, options)
    -- ... body ...
end

WG.ObjectSpotlight = {
    addSpotlight = addSpotlight,
}

-- 2. Direct field assignment — moved to function expression
---Recursively turns a table into a string, suitable for printing.
---@param tbl table
---@param options table Optional parameters
---@return string
local tableToString  -- forward decl
tableToString = function(tbl, options, _seen, _depth)
    -- ... body ...
end

table.toString = tableToString
```

**Edge case — `@field` on a `@param options table`:** When the
re-export annotates an `options` parameter with sub-fields like
`@param options.duration number`, those `@param options.X` lines must
also move with the rest of the block. They are valid syntax above a
`local function` declaration.

**If the function definition is in a different file** (rare — usually
means the re-export is doing real work, not just shimming an upvalue):
flag UNCATEGORIZED. Don't try to chase the cross-file reference.

**CRITICAL pitfall — DO NOT try to "disable" annotations by adding a
space:** EmmyLua is more permissive than the older sumneko LSP and
recognizes BOTH `---@param` (no space) AND `--- @param` (with space)
as type annotations. A worker that "fixes" the error by inserting a
space is doing nothing — the analyzer still produces the same error,
the file is dirtier, and the original annotation is lost. The
**only** correct fix is to relocate the `---@param`/`---@return` block
to the function definition. If you can't find the function definition
in the same file, flag UNCATEGORIZED and stop. Do not edit the line
unless you are moving annotations to a real function declaration.

### Category 46: Hoisted-local forward declaration

**Error:** `undefined global variable: <name>` where `<name>` IS assigned
inside the same file but the assignment is in a deeper lexical scope
(inside a function body, an `if` block, a `for` loop, etc.) than the
read site that errors.

**How to recognize:** Search the file for `<name>` (or `<name> =` /
`local <name> =`). If the only definitions live inside a nested scope
but the error site is at module level (or in a sibling function, or
inside an unrelated function), this is the pattern.

**Cause:** Lua scoping. `local x = 5` inside a function only exists for
that function's lifetime. References outside that function fall through
to the global table, where `x` is nil. The original author either
intended `x` to be a module-level upvalue (and forgot to hoist the
declaration) or to be cleared between calls (in which case the read
site is reachable when the value is nil — a real runtime bug).

**Fix:** Add a forward declaration `local <name>` (no initializer, or
`= nil` / `= false` / `= 0` / `= {}` to match the type the rest of the
file expects) at the top of the enclosing module-level scope, ABOVE all
references and assignments. The existing nested assignments become
regular reassignments to the upvalue. Idempotent: re-running on
already-hoisted code is a no-op (the local already exists, the analyzer
is happy).

```lua
-- WRONG (running is set inside a callback, read in a sibling function)
local function StartHook()
    running = true   -- creates a NEW global, not the local we want
end

local function CheckHook()
    if hookset then
        if not running then  -- error: undefined global 'running'
            KillHook()
        end
    end
end

-- RIGHT (forward declaration at file scope)
local running = false   -- hoisted; matches the boolean default

local function StartHook()
    running = true   -- now reassigns the upvalue
end

local function CheckHook()
    if hookset then
        if not running then  -- reads the upvalue
            KillHook()
        end
    end
end
```

**Default value selection** — pick whatever matches the file's existing
usage:
- Booleans → `false` (or `nil` if the code distinguishes "unset" from "false")
- Numbers → `0`
- Strings → `""`
- Tables → `nil` (so the code's existing `if <name> ~= nil` guards still fire)
- Functions → `nil` (most file-scope forward decls)
- GL display lists / VBO IDs → `nil` (so `if <name> ~= nil then glDeleteList(<name>) end` still works)

**Edge case — `noRushTime` style "set in widget callin, read at module level":**
The fix is the same. Hoist `local noRushTime = 0` at file scope. The
callin assignment becomes a regular reassignment.

**When NOT to use this category** — flag UNCATEGORIZED instead if:
- The variable name appears nowhere else in the file (it's a typo or
  references something cross-file — Cat 13 territory)
- The fix would change visible runtime semantics in a non-trivial way
  (e.g. reading an unset value used to crash, hoisting hides the crash)

**Special case — `self` outside a `:method` body:** Real bug. `self` is
only defined inside `widget:method(...)` / `gadget:method(...)` /
`addon:method(...)` bodies. References from `local function ...` blocks
or module scope resolve to nil. The intended fix is almost always to
replace `self` with the file-scope `widget` / `gadget` / `addon` upvalue
(both files reference the local with `local widget = widget --type Widget`
at the top). In `:method` bodies `self == widget` so the substitution
is a no-op; in plain functions it picks up the correct value.

This is an env-layer fix (tracked on `fmt-llm-source`), NOT a worker
fix — the substitution is mechanical but the *decision* that `widget`
is the right replacement requires reading the file's idiom and
understanding BAR's widget lifecycle. See the env commit's
"Manual judgment-call fixes" section for an example
(widget_selector.lua + gui_options.lua, 8 sites total).

Workers seeing `undefined-global: self` should flag UNCATEGORIZED with
the note "self-outside-:method, env-layer fix" so maintainers can pick
it up in the next env-layer pass.

### Category 45: Unit script piece-name globals

**Error:** `undefined global variable: <piecename>` in a unit script file
where `<piecename>` is something like `lloarm`, `rloarm`, `torso`,
`luparm`, `ruparm`, `dirt`, `flare`, etc.

**Cause:** Unit scripts run in the engine's unit-script sandbox, which
exposes model piece names as globals at runtime via metatable. The
analyzer has no way to know which pieces a given unit declares.

**Match scope** — apply this category if EITHER:
- The file lives under `scripts/Units/**/*.lua` (per-unit script), OR
- The file lives under `scripts/headers/**/*.lua` (shared unit-script
  header that gets `include`d into scripts and references piece globals)

**Fix:** Add a single file-level diagnostic disable at the top of the
file (NOT `disable-next-line` — that only affects one line, useless
when there are dozens of references). Idempotent.

```lua
---@diagnostic disable: undefined-global
function DrawWeapon(id)
    Turn(lloarm, 1, ang(-90), ang(300))
    Turn(rloarm, 1, ang(-90), ang(300))
    ...
end
```

For files outside the unit-script path, prefer Category 13 (declare a
local) or Category 43 (self-shadow capture).

**Cleanup of stacked stubs:** If a previous pass left multiple
`---@diagnostic disable-next-line: undefined-global` lines stacked at the
top of the file (those don't work), replace them with a single
`---@diagnostic disable: undefined-global` (no `-next-line`).

---

## Structural Type Fixes (env-layer reference)

These are applied to the env layer (`fmt-llm-source` branch + engine PRs) before
the worker run. They are listed here so workers recognize the patterns and don't
attempt to fix them per-file. If you see a related error after the env layer is
in place, flag it as UNCATEGORIZED.

### GL Type Alias
`types/GL.lua`: `---@alias GL integer`

### Widget/Gadget/Addon Open Types
`types/Widget.lua`, `types/Gadget.lua`, `types/Addon.lua`: `---@field [string] any`

### Engine Shader Params
`LuaShaders.cpp`: `@param shaderID Shader|integer` on all shader functions.

### Engine Optional Params
Many engine APIs have `luaL_opt*` for optional params. A maintainer adds `?` to
`@param` annotations in engine C++ and regenerates the stubs via `just lua::library`.

### Engine Missing Function Annotations
Some engine functions lack `@function` doc blocks. A maintainer adds them and
regenerates the stubs. Example: `gl.LoadFont` was missing, now annotated with `@return LuaFont`.

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
