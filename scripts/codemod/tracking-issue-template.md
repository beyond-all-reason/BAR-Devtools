# BAR type-error cleanup: coordinated merge

## Merge plan — stacked PRs

Each PR shows only its own layer's diff. When a parent merges, GitHub auto-retargets the child to `master`.

```
master ← fmt ← mig ← fmt-llm-source ← fmt-llm
```

| Layer | What it does | Merge when |
|-------|-------------|------------|
| **fmt** | `stylua .` across the entire codebase | Ready now — merge once Windows testing confirms `setup::init` works in WSL2 |
| **mig** | All automated transforms — heavier changes (spring-split, i18n-kikito) plus simpler mechanical ones (bracket-to-dot, rename-aliases, busted-types, etc.) | After `fmt` lands and contributors have run `just bar::fmt-mig` on their branches |
| **fmt-llm-source** | Human-curated env layer (`.emmyrc.json`, `types/*` stubs, explicit type ignores, CI gate, manual fixes) | After `mig` — this is the reviewable env prep |
| **fmt-llm** | LLM type-fix pass + `.git-blame-ignore-revs` | After `fmt-llm-source` — final layer, drives type errors to zero |

**For contributors:** Run `just bar::fmt-mig` after rebasing onto master. This replays all transforms idempotently. See the [BAR-Devtools README](https://github.com/beyond-all-reason/BAR-Devtools#readme) for setup.

## PRs

- [ ] **fmt** — [StyLua formatting](https://github.com/beyond-all-reason/Beyond-All-Reason/pull/7199)
- [ ] **mig** — [Combined transforms](https://github.com/beyond-all-reason/Beyond-All-Reason/pull/7229) (base: `fmt`)
- [ ] **fmt-llm-source** — env layer (base: `mig`)
- [ ] **fmt-llm** — [LLM capstone](https://github.com/beyond-all-reason/Beyond-All-Reason/pull/7407) (base: `fmt-llm-source`)
- [ ] [Script / tooling PR (BAR-Devtools)](https://github.com/beyond-all-reason/BAR-Devtools/pull/17)
- [ ] [Recoil PR (lua-doc-extractor wiring + missing type decorators)](https://github.com/beyond-all-reason/RecoilEngine/pull/2799)
    - [ ] [CircuitAI — `zk` branch](https://github.com/rlcevg/CircuitAI/pull/136)
    - [ ] [CircuitAI — `barbarian` branch](https://github.com/rlcevg/CircuitAI/pull/137)

## What this contains

- Automated script (`just bar::fmt-mig-generate`) that rebuilds all branches deterministically from `master`
- [lua-doc-extractor refinements](https://github.com/rhys-vdw/lua-doc-extractor/pull/77) enabling `SpringSynced` / `SpringUnsynced` / `SpringShared` as mutually exclusive engine API wrappers
- Updated [Recoil](https://github.com/beyond-all-reason/RecoilEngine/pull/2799) with new extractor + missing type decorators
- Replaced bespoke i18n with [kikito-i18n](https://github.com/kikito/i18n.lua) via lux — first forced dependency, hidden behind `just setup::distrobox`
- New PR gate: "Type Check" (`just bar::check`)
- Replaced LuaLS/Sumneko with [EmmyLua](https://marketplace.visualstudio.com/items?itemName=tangzx.emmylua) (~100x faster). **Never use the Sumneko VS Code plugin.**

<!-- GENERATED:BRANCH_TOPOLOGY -->

<!-- GENERATED:MUSEUM_TABLE -->

## New developer commands

- `just bar::check` → type-check (EmmyLua)
- `just bar::fmt` → format (StyLua)
- `just bar::test` → unit + integration tests
- `just bar::lint` → lint (luacheck)
- `just setup::editor` → editor integration (language servers, extensions, settings)
- `just bar::fmt-mig` → replay all transforms onto your branch

## Credits

- **@rhys_vdw** — lua-doc-extractor and recoil-lua-library foundation
- **@thule** — BAR-Devtools shared scripting layer
