# BAR type-error cleanup: coordinated merge

## PRs

Stacked — merge bottom-up. Each PR's own diff is scoped to its layer; stack navigation is on each PR.

- [ ] [**fmt** — StyLua formatting](https://github.com/beyond-all-reason/Beyond-All-Reason/pull/8395)
- [ ] [**mig** — combined deterministic transforms](https://github.com/beyond-all-reason/Beyond-All-Reason/pull/8396)
- [ ] [**fmt-llm-source** — hand-curated env layer (emmylua config, types, manual fixes)](https://github.com/beyond-all-reason/Beyond-All-Reason/pull/8397)
- [ ] [**fmt-llm** — LLM type-fix capstone](https://github.com/beyond-all-reason/Beyond-All-Reason/pull/8398)
- [ ] [**Bulk Migration** — CI action that replays migrations onto an open PR](https://github.com/beyond-all-reason/Beyond-All-Reason/pull/8662) — not part of the stack; mergeable first, and inert until the tooling stack lands
- [ ] Tooling stack (BAR-Devtools): https://github.com/beyond-all-reason/BAR-Devtools/pull/57/
- [ ] [Mission kit — DSL recognizer, validator, live editor service (BAR-Devtools)](https://github.com/beyond-all-reason/BAR-Devtools/pull/54)
- [ ] [Recoil PR (lua-doc-extractor wiring + missing type decorators)](https://github.com/beyond-all-reason/RecoilEngine/pull/2799)
    - [ ] [CircuitAI — `zk` branch](https://github.com/rlcevg/CircuitAI/pull/136)
    - [ ] [CircuitAI — `barbarian` branch](https://github.com/rlcevg/CircuitAI/pull/137)

> **Important:** Do not run `just bar::migrate::stylua-cleanup` until `fmt` has merged. Running it earlier reformats the entire codebase on your branch (~200k lines).

<!-- GENERATED:BRANCH_TOPOLOGY -->

<!-- GENERATED:MUSEUM_TABLE -->

**For contributors — after `fmt` merges, update your open branches:**
```bash
just bar::migrate::stylua-cleanup      # transform your branch first
git commit -am "apply code transforms"  # squashed away when PR merges
git merge origin/master                 # conflicts are now real conflicts only
```
See the [BAR-Devtools README](https://github.com/beyond-all-reason/BAR-Devtools#readme) for setup.

Nothing to set up if you'd rather not: ask a maintainer to run the [**Bulk Migration**](https://github.com/beyond-all-reason/Beyond-All-Reason/pull/8662) action on your PR and it does the above for you, on the same code path, and pushes the result back. It replays every migration still listed under `bar::migrate` — oldest first, skipping the ones your branch already has — so it stays useful past this one. It bails without pushing if the merge conflicts for reasons the transforms can't account for; those are yours to resolve.

Maintainers: `gh workflow run bulk_migration.yml --repo beyond-all-reason/Beyond-All-Reason -f pr=<number>`, or the Actions tab. If the PR is from a fork, the result is parked on `migrate/pr-<number>` and the comment gives the author a one-line `git pull` — `GITHUB_TOKEN` cannot push to a fork even with *Allow edits by maintainers*.

`.git-blame-ignore-revs` arrives with the capstone. Until it is on `master`, `git blame` will abort with `could not open object name list` on any branch that predates it — clear it with `git config --unset blame.ignoreRevsFile` if you hit that before the stack lands.

## What this contains

- Automated script (`just bar::migrate::stylua-cleanup-generate`) that rebuilds all branches deterministically from `master`
- Updated [Recoil](https://github.com/beyond-all-reason/RecoilEngine/pull/2799) with new extractor + missing type decorators
- New PR gate: "Type Check" (`just bar::check`) — errors only, so warnings and hints stay local
- `.git-blame-ignore-revs` listing the mechanical commits, so `git blame` walks past the formatting and codemod layers to the author who actually wrote the line
- Replaced LuaLS/Sumneko with [EmmyLua](https://marketplace.visualstudio.com/items?itemName=tangzx.emmylua) (~100x faster). **Never use the Sumneko VS Code plugin.**


## New developer commands

- `just bar::check` → type-check (EmmyLua)
- `just bar::fmt` → format (StyLua)
- `just bar::test` → unit + integration tests
- `just bar::lint` → lint (luacheck)
- `just setup::editor` → editor integration (language servers, extensions, settings)
- `just bar::setup-hooks` → pre-commit hook that checks staged Lua against StyLua and refuses if it is unformatted; also points `git blame` at `.git-blame-ignore-revs`
- `just bar::migrate::stylua-cleanup` → replay all transforms onto your branch

### Generation pipeline: `just bar::migrate::stylua-cleanup-generate --update-prs`

0. Fetch origin and rebase prereq branches onto master.
1. **Deterministic text transformations** — ~99.9% mistake-free once I've validated a transform, basically free to re-run.
2. **Non-deterministic pass** (LLM + rules to categorize type errors with relatively simple heuristics). This targets the ~110 type errors remaining after the globals are cleaned up (the exact count drifts as `master` moves), and crucially, most of them are actual bugs that'll improve code quality once fixed.
3. Update PRs with output.

### The upshot

- (1) is basically free and VERY reliable.
- (2) just requires we read it, test it, make any fixes, then either update our rules or merge ASAP.

### Step 2 detail

Step 2 is the interesting part. I arrived at these rules by dispatching cheap subagents in parallel, then having an orchestrator agent refine the rules and re-run until the cheaper models covered all the edge cases. Because all of these fixes are well below the waterline for an Opus-calibre agent to explain to a GPT 5.4 Mini class of agent, this works. It gives us cheap, repeatable, and mostly idempotent execution on top of master.

Really effective for this sort of problem — in the past it would've been a month of hand editing and hating my life to get to zero, plus another month agonizing over which problems were worth a deterministic transform vs. just grinding through. =D

## Closing thoughts

- I think this will let us actually use the formal type system to fuller effect (because people treat it as a real signal) and will greatly increase code quality in BAR over time.
- The more formal verification we wire in, the better our parsers and LLM agents get and the faster we can move on systemic problems.
- This makes the argument made in [Game Economy](https://github.com/beyond-all-reason/RecoilEngine/pull/2664) more compelling (and I confess that's what led me here). The idea of moving subsystem by subsystem out of the engine and into Lua modules (that may or may not live in the game) makes waaaaaaay more sense when you have types enforced. Suddenly Lua can express its own design patterns under type checking — both where the engine has no stake (most of the game outside the sim) and where it does, by wrapping the engine API in typed abstractions instead of leaking it everywhere. cc @sprunk

## Credits

- **@rhys_vdw** — thanks for the fantastic foundation in lua-doc-extractor and recoil-lua-library. Doing all of those decorators by hand must've been unbelievably labor intensive and there is not a snowball's chance in hell I would've even started this project unless that work already existed.
- **@thule** — super enabled by BAR-Devtools existing, shout out for getting that ball rolling. SHARED CROSS REPO SCRIPTING LAYER!!!!!
