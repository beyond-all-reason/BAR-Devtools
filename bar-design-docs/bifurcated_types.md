# Bifurcated Types

Splitting the monolithic `Spring` table into context-correct namespaces so BAR's
Lua can be type-checked — and why that requires **BAR-Devtools**.

## The problem

BAR's Lua runs in several engine contexts that expose **different** APIs:

- **synced** — gadgets / simulation (`LuaRules`)
- **unsynced** — widgets / UI (`LuaUI`)
- **defs** — unit/weapon/feature parsing (the `LuaParser` sandbox)

The engine hands every context a single global `Spring` table, but the functions
that are actually *valid* differ by context (synced-only, unsynced-only, or
shared reads). A flat `Spring` type can't express that, so the analyzer can't:

- tell you a synced-only call from a widget is wrong,
- resolve the right overload/signature per context.

On top of that, **BAR bolts its own helpers onto `Spring`** — `Spring.I18N`,
`Spring.Utilities`, `Spring.Debug`, `Spring.Lava`, `Spring.GetModOptionsCopy`.
These aren't engine API; they pollute the `Spring` type and collide with the
engine stubs, so type-checking against the real engine surface is impossible.

Net effect: thousands of `emmylua` diagnostics and no way to gate type safety in
CI.

## The solution: bifurcate the namespace

**1. Split the engine API by context.**

```
Spring.X  ->  Engine.Synced.X      (valid only in synced)
          ->  Engine.Unsynced.X    (valid only in unsynced)
          ->  Engine.Shared.X      (reads valid in both — e.g. LuaSyncedRead)
```

The bucket is chosen per call from the engine's own type stubs, so the analyzer
resolves each call in the correct context and flags misuse.

**2. Detach BAR modules into a `BAR` namespace** (kept off the root global ns):

```
Spring.I18N  ->  BAR.I18N
Spring.Utilities / Debug / Lava / GetModOptionsCopy  ->  BAR.*
```

Member names are preserved (pure namespacing), which keeps the engine `Spring`
stubs clean and the BAR surface explicit.

## How it works (cross-repo, orchestrated by BAR-Devtools)

| Layer | Repo | What it provides |
|-------|------|------------------|
| **Runtime** | RecoilEngine | The gameplay VMs and the `LuaParser` defs env natively expose `Engine.{Synced,Unsynced,Shared}`; the defs parser aliases `Engine.Shared` to its `LuaSyncedRead` reads. |
| **Type stubs** | recoil-lua-library | Declares which bucket each engine function lives in — the source of truth the codemod reads. |
| **Codemod** | bar-lua-codemod | Deterministic full_moon AST transforms: `spring-split`, `detach-bar-modules`, `bracket-to-dot`, `rename-aliases`, `i18n-kikito`. |
| **Migration stack** | BAR-Devtools | `just bar::fmt-mig-generate` deterministically rebuilds `fmt` (stylua) → one leaf PR per transform → `mig` (all transforms) → `fmt-llm` (env layer + LLM type-triage to 0). |
| **Test harness** | Beyond-All-Reason | Three sandboxes — widget, gadget, **and defs** — each need `Engine`/`BAR` wired. Busted shims (a `spec_helper` Engine→Spring proxy, the engine builder mocks) mirror what the engine provides. |
| **CI gate** | Beyond-All-Reason | `emmylua_check` (pinned to the same version as the dev container) enforces **0 errors**. |

Three things that are easy to miss and break the build if skipped:

- The **defs** sandbox is a third `system.lua`, separate from widget/gadget. Unit
  defs call `Engine.Shared.GetModOptions()` / `BAR.Utilities.*` at file scope, so
  the parser env (real engine **and** the busted mock) must expose both.
- **Runtime support is engine-provided, not shimmed in BAR.** BAR-side shims are
  only for the no-engine busted VM (tests), never for the game.
- The whole thing is **deterministic** — same `master` in, same stack out.

## Why BAR-Devtools must be required

1. **Reproducibility.** The migration stack — formatting, the type bifurcation,
   the path to 0 errors — is only reproducible via `just bar::fmt-mig-generate`.
   Without BAR-Devtools there is no way to regenerate or review it.
2. **Toolchain lockstep.** stylua, `emmylua_check` (pinned), and `lux` versions
   are managed by BAR-Devtools. Version skew silently breaks CI (e.g. lockfile
   integrity). Pinning them in one place is the only way to keep local == CI.
3. **Local == CI.** Contributors need BAR-Devtools to run the exact format/type
   check the CI gate enforces, before pushing.
4. **Cross-repo orchestration.** The bifurcation spans engine + Lua library +
   game + tests. BAR-Devtools is the only thing that drives that change
   coherently across the sibling repos.

## Status

- `stylua` across the entire Lua tree — done (the `fmt` baseline).
- `Engine.{Synced,Unsynced,Shared}` split + `BAR` namespace — codemod + engine +
  test harness in place; the capstone (`fmt-llm`) drives `emmylua_check` to 0.
- CI gate (`type_check.yml`) enforces 0 errors on the capstone.

## Ask

Make BAR-Devtools a required part of the contributor workflow for anyone touching
Lua, so type safety and formatting are reproducible and gated rather than
best-effort.
