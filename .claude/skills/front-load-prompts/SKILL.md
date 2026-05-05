---
name: front-load-prompts
description: All interactive decisions in long-running setup scripts go in one batch at the top, before any work runs. Use this when adding a new prompt to `cmd_init`, `setup::init`, or any multi-minute recipe — it explains the "Step 0/N Configuration" pattern and why we don't sprinkle Y/n prompts through the steps.
---

# Front-load prompts

`setup::init` does ~5 minutes of distrobox image build + ~5 minutes of repo clones + several minutes of engine build. The contributor walks away during that time. **Every interactive prompt belongs before the first long-running step**, captured into a variable that the later step reads.

## The Step 0 pattern

```bash
cmd_init() {
  ensure_wsl_setup
  _setup_consent_splash       # press-Enter + sudo -v cache

  # Front-load all decisions ----
  step "0/N  Configuration"
  ensure_bar_devsync_dir      # WSL: pick sync target (writes .env)
  pick_features               # component selection -> $features
  local game_dir do_link=""
  game_dir="$(detect_game_dir 2>/dev/null)" || true
  if [ -n "$game_dir" ]; then
    read -rp "Symlink all selected components after build? [y/N] " do_link
  fi
  prompt_springsettings_opt_in

  # Then run -----
  step "1/N  ..."   # uses $features, $do_link, env vars
  ...
}
```

Each later step reads the captured answer; no second prompt for the same decision.

## What "running setup::init is itself the consent" means

The `_setup_consent_splash` shows a fact-driven list of system changes (apt installs, sysctl bump, distrobox container) and waits for a single Enter. That's the only generic Y/n. After that, **the user has consented to the script running** — no per-step "Install X? [Y/n]" gates. If the user wanted to back out, they'd Ctrl-C; the script doesn't owe them another off-ramp partway through.

This applies to `distrobox stop --yes`, `distrobox rm -f --yes`, `distrobox create --yes`, `apt install -y`. Any sub-tool that has an interactive default needs the non-interactive flag.

## Inverting the symlink prompt

The old shape had `read -rp "Symlink all? [y/N]"` *inside* step 6 ("Symlinks"), gating cmd_link calls. The new shape asks the question in step 0 (when the user is paying attention) and step 6 just runs (or skips with `Skipping symlinks (declined at configuration step)`). Same logic for any other "should I do X" decision: ask up front, act later.

## Don't re-prompt for state already in `.env`

`prompt_springsettings_opt_in` checks `grep -q "^ALLOW_SPRINGSETTINGS_MOD=" "$env_file"` and skips the prompt if it's set. Same for `BAR_DEVSYNC_DIR`. Re-runs of `setup::init` should noop on questions the user already answered. If they want to re-decide, they edit `.env`.

## Audit checklist when adding a step

- Does the step have a `read -rp` or Y/n prompt? → move it to step 0, capture into a variable.
- Does the step call a sub-tool with an interactive default? → add `--yes` / `-y` / `--non-interactive`.
- Does the step `read -p` for a path or value? → if it's a real configuration choice, move it to step 0 and persist via `.env` so re-runs skip it.
- Is the prompt conditional on detection that requires earlier setup (e.g. `detect_game_dir`)? → fine, but the *prompt* still goes in step 0 after the detection runs, not buried in step 6.
