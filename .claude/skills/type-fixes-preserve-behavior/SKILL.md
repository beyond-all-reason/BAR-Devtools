---
name: type-fixes-preserve-behavior
description: A type-error fix may change types and names — never behavior. Use when clearing emmylua_check errors in the Beyond-All-Reason tree, or on any pass that renames locals, adopts a namespace (Spring.X -> BAR.X), or edits a file to satisfy the analyzer. It encodes the gui_chat.lua regression that shipped a widget that would not load.
---

# Type fixes preserve behavior

`emmylua_check` reports a *type* problem. The fix is a type annotation, a declaration, or a name — never a restructured function, never a dropped field, never an inlined recomputation. A green analyzer on a widget that no longer loads is worse than the error it replaced.

## The rule

**Every edit is reversible into "same program, better typed."** If you cannot state the change as a rename, an annotation, or a declaration, you are no longer fixing a type error.

## Renames are total or they are not done

Renaming a local means renaming *every* reader in the file, in one pass. Count the references before and after — they must match.

```lua
-- state table renamed I18N -> i18nStrings
local i18nStrings = state.i18nStrings   -- renamed
...
local modeText = I18N.everyone          -- NOT renamed: now a nil global
```

A partial rename is silent at load and crashes on the first draw. `grep -c` the old name after the edit; the answer is 0.

## A namespace prefix is not noise

`Spring.I18N(...)` -> `BAR.I18N(...)` is the migration. `BAR.I18N(...)` -> `I18N(...)` is a bug, unless the file declares `local I18N = BAR.I18N` — and if it does, that declaration must be in the same edit.

Bare `I18N(` reads as a local alias. Grep the file for the `local ... = BAR.` line before assuming one exists.

## Never drop a table field

A key removed from a constructor is a runtime nil at every read site. Two keys (`channelScopeAll`, `label`) went missing from a table while its readers stayed — both would have returned nil forever.

Diff the constructor key-set before and after. It only grows.

## Never introduce shadowing recomputation

Do not re-declare inside a closure what the enclosing function already computed. Fifteen such lines were inserted into a `glCreateList(function() ... end)`, recomputing `isCmd` *without* the `isLabel` branch the outer scope had — a behavior regression the analyzer is blind to.

If a closure needs a value, it already has it as an upvalue.

## Not every .lua file is Lua

`mapgenerator/mapinfo_template.lua` is a `${PLACEHOLDER}` template. A bare
`${START_POSITIONS}` inside a table is a parse error, and commenting it out
silences the analyzer while breaking every generated map — the substituted
block lands behind a `--`.

A file the analyzer cannot parse for a structural reason belongs in
`.emmyrc.json` `workspace.ignoreDir`, not in your edit set. Ask what the file
*is* before treating a diagnostic on it as a defect.

## Repair to the intent, not to whatever is in scope

`stompableDefs[udid] = v` — `v` leaked from a previous loop and was nil, so the
table was always empty. `ud` is in scope and makes the error go away; `true` is
what the code meant, because the only read is `if stompableDefs[unitDefID]`.

When a table is used as a set, the value is `true`. Look at the read sites
before choosing the write.

## Verify before committing

- `luajit -bl <file> >/dev/null` — syntax.
- `git diff <pre-pass-commit> -- <file>` — every changed line is a rename, an annotation, or a declaration. Line count does not grow.
- Load the game and read `infolog.txt` for `Failed to load:`. The analyzer cannot see a nil global that is only called at load.
