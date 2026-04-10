# Type Triage Subagent Prompt

Use this prompt verbatim when launching subagents for LuaLS type error triage.
Replace `CHUNK_NUMBER` with the actual chunk number (1-6).

---

You are applying type-annotation-only fixes to Lua files in `/home/daniel/code/Beyond-All-Reason/`.

## Inputs

1. Read `/home/daniel/code/bar-design-docs/errors-chunk-CHUNK_NUMBER.txt` — your assigned errors.
2. Read `/home/daniel/code/bar-design-docs/claude/skills/codemod-prereq/SKILL.md` — the fix procedures. Every category marked **(subagent)** is YOUR responsibility.

## Critical Rules

- Do NOT change program logic or functionality. Only fix type annotations and type errors.
- Do NOT edit `.luarc.json` — that is the orchestrator's job.
- Do NOT edit files under `recoil-lua-library/` — those stubs are static.
- Do NOT edit engine C++ files — those are the orchestrator's job.
- You MAY create or extend files under `types/` (one class per file, `---@meta` header).
- Do NOT create type files for classes already defined in `recoil-lua-library/` or `modules/graphics/instancevbotable.lua` (VBO, VAO, Shader, LuaFont, InstanceVBOTable, Callins, Widget, Gadget, Addon).
- `---@cast` ONLY works on local variables, NEVER on `tbl.field` paths. Use `--[[@as Type]]` inline for table fields.
- NEVER use `--[[@as integer[]]]` (or any `...[]`) — `]` ends the block comment and breaks parsing. Use `---@cast myLocal integer[]` on the next line, or `---@alias MyArr integer[]` and `--[[@as MyArr]]`.
- NEVER add `---@class Widget`, `---@class VAO`, or `---@class VBO` inside widget files; it poisons global merges. Use `local widget ---@type Widget = widget` only.
- BAR shader objects from `gl.LuaShader(...)` are `BarLuaShader`, not `Shader` (Shader = integer program ID). Use `---@type BarLuaShader?` and extend `types/BarLuaShader.lua` if methods are missing.
- You MUST attempt a fix for EVERY error in your chunk. No skipping.
- If no SKILL.md category matches an error, report it as UNCATEGORIZED.

## Fix Priority (from SKILL.md)

For each error, match it to the FIRST applicable SKILL.md category:

1. **`undefined-field` on VBO/VAO** → Category 16: Add `---@type VBO`/`VAO` at creation site; use `assert(gl.GetVBO(...))` when the path must not continue on failure
2. **`undefined-field` on `:SetUniform` / `:Activate` on gl.LuaShader result** → Category 38: `---@type BarLuaShader?`, not `Shader`
3. **`undefined-field` on font methods** → Category 20: Add `---@type LuaFont` at `gl.LoadFont()` site
4. **`need-check-nil`** → Category 35: Guard, default, or cast (see 5 rules in SKILL.md)
5. **`param-type-mismatch nil→number`** → Category 21/26: Add `or 0` or `--[[@as number]]`
6. **`param-type-mismatch number?→number`** → Category 26: Add `or 0` or `--[[@as number]]`
7. **`param-type-mismatch string→number`** → Wrap in `tonumber(x) or 0`
8. **`param-type-mismatch string↔stringlib`** → Category 27: `---@diagnostic disable-next-line: param-type-mismatch`
9. **`cast-local-type`** → Category 36: Add `---@type X|Y` before declaration
10. **`assign-type-mismatch`** → Category 37: Add `--[[@as Type]]` cast
11. **`missing-parameter` on callin bootstrap** → Category 25: Pass full args
12. **`redundant-parameter` on `GetGameRulesParam(name, 0)`** → Category 33: Use `or 0`
13. **`duplicate-index`** → Category 28: Remove duplicate key
14. **`duplicate-doc-field`** → Category 30: Consolidate `@class` (one file per class in `types/`)
15. **`undefined-global` (lowercase variable)** → Category 13: `local varName = default`
16. **`if not Spring then`** → Category 18: Delete guard or replace with `SpringShared`
17. **`SetGameRulesParam` with boolean** → Category 32: Convert or report
18. **`self.X` in module** → Category 19: Replace with `ModuleName.X`
19. **`math.fract`** → Category 24: Replace with `(x - math.floor(x))`
20. **Forward-compat guards** → Category 14: Comment out with note

## Output Format

Return your results in this exact structure:

```
FIXED:
  - path/to/file.lua: L123 (Category N) — description of change

ATTEMPTED:
  - path/to/file.lua: L456 (Category 35, need-check-nil in game logic) — what you did, flagged for review

UNCATEGORIZED:
  - path/to/file.lua: L789 — error message, what pattern you observed, suggested fix if any
```

Work through EVERY file in your chunk. Batch edits per file. Do not stop early.
