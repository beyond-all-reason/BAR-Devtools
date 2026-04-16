# BAR type-error cleanup: coordinated merge

> [!IMPORTANT]
> The BAR-Devtools PR needs to land before the release cut — it contains the docs and recipes that shape how contributors onboard to the new workflow.

## Status

The BAR type-error cleanup is done. I've moved all three PRs out of draft and tested the scarier bits, specifically around the i18n migration. These are ready to go barring concerns — I'll maintain them furiously for at least another week and have rebased my own branches on top of them so I'm feeling any rough edges before you do.

## PRs to merge

- [ ] [Final BAR transform output PR](https://github.com/beyond-all-reason/Beyond-All-Reason/pull/7407)
- [ ] [Script / tooling PR (BAR-Devtools)](https://github.com/beyond-all-reason/BAR-Devtools/pull/17)
- [ ] [Recoil PR (lua-doc-extractor wiring + missing type decorators)](https://github.com/beyond-all-reason/RecoilEngine/pull/2799)
    - [ ] [CircuitAI — `zk` branch (vendored as `AI/Skirmish/CircuitAI`)](https://github.com/rlcevg/CircuitAI/pull/136)
    - [ ] [CircuitAI — `barbarian` branch (vendored as `AI/Skirmish/BARb`)](https://github.com/rlcevg/CircuitAI/pull/137)

> Recoil's `.gitmodules` pins two submodules to the same `rlcevg/CircuitAI` repo but at different branches (`zk` and `barbarian`) — the Spring-API split rewrite has to land on both branches so both vendored AIs keep compiling. Mechanical rename, cherry-picked across.

## What this spike contains

- An automated script that generates independent and combined PRs — the deterministic transforms in one pass, then an LLM pass that drives type errors to zero.
- [Refinements to the lua-doc-extractor](https://github.com/rhys-vdw/lua-doc-extractor/pull/77) enabling `SpringSynced` / `SpringUnsynced` / `SpringShared`, which act as mutually exclusive wrappers for the engine API.
- Updated [Recoil](https://github.com/beyond-all-reason/RecoilEngine/pull/2799) to use the lua-doc-extractor changes and inject the correct global aliases for Spring into the correct fenv. In the process, added lots of missing type decorators to `recoil-lua-library`. cc @badosu @rhys_vdw
- Replaced our bespoke i18n library with [kikito-i18n](https://github.com/kikito/i18n.lua) via the package manager, added a shim for `VFS.Include`, and updated every call site via a transform. This is the first BAR dependency that actually forces package management — but `just setup::distrobox` hides it: one command builds a container with `lx` (the Lua package manager), Lua 5.1, stylua, and busted preinstalled, and every `just bar::*` recipe auto-enters it. Contributors never install rocks, pick a Lua version, or touch their host toolchain. cc @watchthefort
- A new BAR PR workflow gate, "Type Check", which runs the equivalent of `just bar::check`.
- Dogfooded the new tools and ripped out LuaLS/Sumneko in favor of [EmmyLua](https://marketplace.visualstudio.com/items?itemName=tangzx.emmylua) (~100x faster, but the configuration is unfortunately mutually exclusive). Added `.emmyrc.json` to the project and `just setup::editor` to wire it all up in one command. **Never use the Sumneko VS Code plugin.**

<details>
<summary>Commit-by-commit breakdown (11 commits)</summary>

### Commits

| # | Commit | What it does |
|---|--------|--------------|
| 1 | [`41f75b6759`](https://github.com/keithharvey/Beyond-All-Reason/commit/41f75b675908b049828a3ef386485ff53b362b66) `env: expose detached BAR modules to widget/gadget sandbox` | expose detached BAR modules to widget/gadget sandbox |
| 2 | [`84978a1e24`](https://github.com/keithharvey/Beyond-All-Reason/commit/84978a1e24ce4a44b914a0f0e79b0eb6fea83fe4) `deps: add kikito/i18n.lua as lux dependency` | add kikito/i18n.lua as lux dependency |
| 3 | [`abe3eb1762`](https://github.com/keithharvey/Beyond-All-Reason/commit/abe3eb17625e05228ea32ae400cab075117e6d95) `gen(stylua): initial formatting of entire codebase` | stylua across the entire codebase |
| 4 | [`f624c194d1`](https://github.com/keithharvey/Beyond-All-Reason/commit/f624c194d1b00adf3f7cac2885df670018328f77) `gen(bar_codemod): bracket-to-dot` | x["y"] → x.y, ["y"]= → y= via full_moon AST rewrite |
| 5 | [`073f0e7938`](https://github.com/keithharvey/Beyond-All-Reason/commit/073f0e7938d44bd9a5f3327d522e4379ee0b7122) `gen(bar_codemod): rename-aliases` | deprecated Spring API aliases (GetMyTeamID → GetLocalTeamID, etc.) |
| 6 | [`6913042dd2`](https://github.com/keithharvey/Beyond-All-Reason/commit/6913042dd2b4f67f0541ae578f424bb9e113f14b) `gen(bar_codemod): detach-bar-modules` | Spring.{I18N,Utilities,Debug,Lava,GetModOptionsCopy} → bare globals |
| 7 | [`b40cbf97c9`](https://github.com/keithharvey/Beyond-All-Reason/commit/b40cbf97c9e67d2c238bcbc23fbf93748f9744e5) `gen(bar_codemod): i18n-kikito` | vendored gajop/i18n → kikito/i18n.lua via lux dependency |
| 8 | [`f6941d6442`](https://github.com/keithharvey/Beyond-All-Reason/commit/f6941d6442f711fb96d7af5baf4ed712fa4fd0cf) `gen(bar_codemod): spring-split` | Spring.X → SpringSynced/SpringUnsynced/SpringShared.X per @context |
| 9 | [`767be19b8f`](https://github.com/keithharvey/Beyond-All-Reason/commit/767be19b8f64f71ab9b7770a272fd31863f258cf) `git-blame-ignore-revs: add transform commits` | register transform commits with git blame |
| 10 | [`a65bd29a6c`](https://github.com/keithharvey/Beyond-All-Reason/commit/a65bd29a6c2e9f835af3fd883c3c878f6e1240b9) `env(llm): emmylua config + type stubs + runtime fixes` | .emmyrc.json globals, types/* stubs, busted mock, CI gate, manual fixes |
| 11 | [`951689d691`](https://github.com/keithharvey/Beyond-All-Reason/commit/951689d69193e7012ad9139f639eda80a95dc78a) `gen(llm): type-error triage (106 → 0 errors)` | parallel LLM workers applying SKILL.md fix recipes per file chunk |

</details>

## New developer commands

- `just bar::check` → check types (emmylua)
- `just bar::lint` → check style (stylua)
- `just setup::editor` → export `emmylua_ls`, `emmylua_check`, and `clangd` to bin, then print copy-pasteable vscode settings and suggested plugins.
- `just bar::fmt-mig` → apply all deterministic transforms to your own branch (see pipeline below).

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
