# Scope and expectations

AI-assisted contributions must follow the [AI Usage Policy](AI_POLICY.md).

## What this repo is for

BAR Devtools provides a local development environment for Beyond All Reason. It spins up Teiserver, PostgreSQL, SPADS, and bar-lobby with a single command, and it wires a contributor's local checkouts into a working engine, lobby, and server stack. This repo is the orchestrator of the local dev experience.

Everything here exists to serve that loop: getting a contributor from clone to a running, testable stack.

## In scope

Anything that keeps the local dev loop working:

- Setup, reconfigure, and bootstrap
- Doctor and diagnostics
- Launch and engine routing
- Repo cloning, syncing, and link management
- Docker and compose configuration
- Just recipes
- Editor wiring and workspace configuration
- Config and defaults for the stack

## Out of scope

Standalone products and pipelines do not belong here. A change belongs here when it serves the local dev loop. A change that ships its own server, editor, or end user interface needs its own repository, its own CI, its own review, and its own maintainers. Once such a project is stable and small, it may be wired into this repo through a normal change.

## Review expectations

- One concern per pull request. A change should be reviewable in one sitting.
- A pull request should stay small enough that a reviewer can reason about the whole diff. A few hundred lines is a good ceiling; thousands is a sign the change needs splitting, or its own repo.
- Keep the diff on topic. Stray files, unrelated renames, and bundled follow up work belong in their own changes.
- Commit messages should describe what changed and why, in plain language, with no typos in the summary line.

## Maintainers

If a change is outside scope, or cannot be reviewed as a single unit, it will be returned for rework before merge. This is a scope decision. Everyone who submits here is expected to help keep the repo reviewable.
