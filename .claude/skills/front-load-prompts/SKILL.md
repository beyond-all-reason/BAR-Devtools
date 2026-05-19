---
name: front-load-prompts
description: All interactive decisions in long-running setup scripts go in one batch at the top, before any work runs. Use this when adding a new prompt to `cmd_init`, `setup::init`, or any multi-minute recipe — it explains the "Step 0/N Configuration" pattern and why we don't sprinkle Y/n prompts through the steps.
---

# Front-load prompts

`setup::init` does ~5 minutes of distrobox image build + ~90 minutes of repo clones + ~45 minutes of engine build. Then, on Windows, potentially sync time. The contributor walks away during that time. **Every interactive prompt belongs before the first long-running step**, captured so a later step reads the answer instead of re-asking.

## The Step 0 pattern

`cmd_init`'s configuration phase (`step "0/N  Configuration"`) is a flat batch: detect what it can, ask every decision, then `confirm_setup_plan` rolls the lot up for one Y/n. Nothing below step 0 prompts.

The prompts are not hand-written `read -rp` calls in `cmd_init` — each decision is a self-registering module under `scripts/setup/NN-<name>.sh`, driven by `ensure_module_by_name`. That mechanism is its own convention; see the **setup-module-registry** skill. The rule *this* skill carries is the ordering: a module's prompt fires in step 0, its `apply` runs whenever it has to (immediately, or deferred to the end of `cmd_init`), but the question is always asked up front.

## Running setup::init is itself the consent

`confirm_setup_plan` closes step 0 with a rollup — every decision the user made, plus the work ahead (repos to clone, whether the distrobox build is still pending, a sudo heads-up) — and a single Y/n. That is the one generic gate. Once the user confirms it, **they have consented to the script running**: no per-step "Install X? [Y/n]". If they want out, they Ctrl-C.

So any sub-tool with an interactive default needs its non-interactive flag — `distrobox stop --yes`, `distrobox rm -f --yes`, `distrobox create --yes`, `apt install -y`. A prompt that fires past step 0 is the bug.

## Ask up front, act later

The load-bearing example is the symlink decision. The question ("symlink the selected components into the game dir after build?") is asked in step 0, when the user is paying attention, and persisted to `.env`. Step 6 ("Symlinks") just acts on the saved answer, or prints `Skipping symlinks (declined at configuration step)`. Same shape for any "should I do X" decision: the prompt goes in step 0, the work goes wherever it has to.

## Audit checklist when adding a step

- Does the step have a `read -rp` or Y/n prompt? → it doesn't belong there. Make it a setup module (see **setup-module-registry**) so the prompt lands in step 0 and the answer persists to `.env`.
- Does the step call a sub-tool with an interactive default? → add `--yes` / `-y` / `--non-interactive`.
- Is the prompt conditional on detection that needs earlier setup (e.g. `detect_game_dir`)? → fine, but the prompt still goes in step 0 *after* the detection, not buried in a later step.
