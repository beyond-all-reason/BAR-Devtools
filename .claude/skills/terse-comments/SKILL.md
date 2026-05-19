---
name: terse-comments
description: Code comments are terse or absent — never multi-line rationale blocks, never narration of what the next line does, never explaining what's missing or why-not. Use when writing or editing any code file (.sh, .just, Containerfile, .py, compose). The repo owner and BAR contributors treat verbose comment blocks as AI clutter.
---

# Terse comments

Code aesthetic and brevity beat exhaustive reasoning. A wall of comment is tiring to read, reads as AI-written, and detracts from the code. Humans don't write them — and BAR contributors notice and dislike them.

## The rule

Default to **no comment**. Write one only for a genuine non-obvious gotcha — a constraint a maintainer would actually trip over — and then **one terse line**, never a paragraph.

## Don't

- Multi-line rationale blocks above a function or stanza.
- Narration — a comment that restates what the next line(s) do.
- Explaining what's *missing* or *why-not*: `# No X here because…`, `# we don't touch Y…`. Absent code needs no comment.
- Decorative banners and section dividers.
- Function-header essays describing args, returns, and history.

## Do

- One terse line for a real gotcha: `# Plan 9 doesn't forward inotify from /mnt/c -- poll instead`.
- Match the sparse comment density of the surrounding human-written code.
- Let names and structure carry the meaning. If a block needs a paragraph to explain, the fix is usually clearer code, not a longer comment.

The "why" belongs in the commit message — and, for a load-bearing design rule, a skill — not sprinkled across every line.

## Scope

Code files: `.sh`, `.just`, `Containerfile`, `.py`, compose YAML. Prose docs (`.md`, `README`, skill files) are exempt — they are meant to be read as prose.
