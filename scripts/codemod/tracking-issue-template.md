# BAR type-error cleanup: coordinated merge

## PRs

Stacked — merge bottom-up. Each PR's own diff is scoped to its layer; stack navigation is on each PR.

- [ ] [**fmt** — StyLua formatting](https://github.com/beyond-all-reason/Beyond-All-Reason/pull/7199)
- [ ] [**mig** — combined deterministic transforms](https://github.com/beyond-all-reason/Beyond-All-Reason/pull/7229)
- [ ] [**fmt-llm-source** — hand-curated env layer (emmylua config, types, manual fixes)](https://github.com/beyond-all-reason/Beyond-All-Reason/pull/7447)
- [ ] [**fmt-llm** — LLM type-fix capstone](https://github.com/beyond-all-reason/Beyond-All-Reason/pull/7407)
- [ ] [Script / tooling PR (BAR-Devtools)](https://github.com/beyond-all-reason/BAR-Devtools/pull/17)
- [ ] [Recoil PR (lua-doc-extractor wiring + missing type decorators)](https://github.com/beyond-all-reason/RecoilEngine/pull/2799)
    - [ ] [CircuitAI — `zk` branch](https://github.com/rlcevg/CircuitAI/pull/136)
    - [ ] [CircuitAI — `barbarian` branch](https://github.com/rlcevg/CircuitAI/pull/137)

> **Important:** Do not run `just bar::fmt-mig` until `fmt` has merged. Running it earlier reformats the entire codebase on your branch (~200k lines).

**For contributors — after `fmt` merges, update your open branches:**
```bash
just bar::fmt-mig                       # transform your branch first
git commit -am "apply code transforms"  # squashed away when PR merges
git merge origin/master                 # conflicts are now real conflicts only
```
See the [BAR-Devtools README](https://github.com/beyond-all-reason/BAR-Devtools#readme) for setup.

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

### Generation pipeline: `just bar::fmt-mig-generate --update-prs`

0. Fetch origin and rebase prereq branches onto master.
1. **Deterministic text transformations** — ~99.9% mistake-free once I've validated a transform, basically free to re-run.
2. **Non-deterministic pass** (LLM + rules to categorize type errors with relatively simple heuristics). This targets the ~106 type errors remaining after the globals are cleaned up, and crucially, most of them are actual bugs that'll improve code quality once fixed.
3. Update PRs with output.

### The upshot

- (1) is basically free and VERY reliable.
- (2) just requires we read it, test it, make any fixes, then either update our rules or merge ASAP.

### Step 2 detail

Step 2 is the interesting part. I arrived at these rules by dispatching cheap subagents in parallel, then having an orchestrator agent refine the rules and re-run until the cheaper models covered all the edge cases. Because all of these fixes are well below the waterline for an Opus-calibre agent to explain to a GPT 5.4 Mini class of agent, this works. It gives us cheap, repeatable, and mostly idempotent execution on top of master.

Really effective for this sort of problem — in the past it would've been a month of hand editing and hating my life to get to zero, plus another month agonizing over which problems were worth a deterministic transform vs. just grinding through. =D

## Closing thoughts

- I think this will let us actually use the formal type system to fuller effect (because people treat it as a real signal) and will greatly increase code quality in BAR over time.
- The more formal verification we wire in, the better our parsers and LLM agents get and the faster we can move on systemic problems. I added `claude/rules/codemod.md` to BAR-Devtools as a driver for the subagents — a literal design document, human-reviewed, giving the agents real structure to work against. Worth doing the same across the rest of our scripts and automation as we take on new projects like this. You could argue these rules belong in individual repos, but BAR-Devtools is the natural home for them.
- This makes the argument made in [Game Economy](https://github.com/beyond-all-reason/RecoilEngine/pull/2664) more compelling (and I confess that's what led me here). The idea of moving subsystem by subsystem out of the engine and into Lua modules (that may or may not live in the game) makes waaaaaaay more sense when you have types enforced. Suddenly Lua can express its own design patterns under type checking — both where the engine has no stake (most of the game outside the sim) and where it does, by wrapping the engine API in typed abstractions instead of leaking it everywhere. cc @sprunk

## Credits

- **@rhys_vdw** — thanks for the fantastic foundation in lua-doc-extractor and recoil-lua-library. Doing all of those decorators by hand must've been unbelievably labor intensive and there is not a snowball's chance in hell I would've even started this project unless that work already existed.
- **@thule** — super enabled by BAR-Devtools existing, shout out for getting that ball rolling. SHARED CROSS REPO SCRIPTING LAYER!!!!!
