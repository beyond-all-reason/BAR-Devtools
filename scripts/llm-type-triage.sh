#!/usr/bin/env bash
# LLM type-triage orchestrator entry point.
#
# Invoked by build_fmt_llm() in generate-branches.sh, but can also be run
# standalone after manually checking out fmt-llm. Spins up a Claude Code
# Opus 4.6 orchestrator that drives parallel claude-sonnet-4-6 subagents
# (one per chunk of error files) to drive `just bar::check` errors toward
# zero.
#
# Inputs (env, with defaults):
#   DEVTOOLS_DIR  -- BAR-Devtools repo root (auto-detected if unset)
#   BAR_DIR       -- BAR repo (default: $DEVTOOLS_DIR/Beyond-All-Reason)
#   ORCHESTRATOR_MODEL  -- Claude model for orchestrator (default: claude-opus-4-6)
#   SUBAGENT_MODEL      -- Claude model passed to subagents via prompt (default: claude-sonnet-4-6)
#   MAX_ITERATIONS      -- Hard cap on orchestrator iterations (default: 5)
#
# Outputs:
#   Edits files under $BAR in-place. Does NOT git commit — that is the
#   caller's responsibility (build_fmt_llm in generate-branches.sh).
#   Writes a run summary to $BAR/.git/llm-triage-summary.txt for the PR
#   body generator.

set -euo pipefail

# ─── Locate repos ────────────────────────────────────────────────────────────

if [[ -z "${DEVTOOLS_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    DEVTOOLS_DIR="$(dirname "$SCRIPT_DIR")"
fi
export DEVTOOLS_DIR

source "${DEVTOOLS_DIR}/scripts/common.sh"

BAR="${BAR_DIR:-${DEVTOOLS_DIR}/Beyond-All-Reason}"
export BAR_DIR="$BAR"

ORCHESTRATOR_MODEL="${ORCHESTRATOR_MODEL:-claude-opus-4-6}"
SUBAGENT_MODEL="${SUBAGENT_MODEL:-claude-sonnet-4-6}"
MAX_ITERATIONS="${MAX_ITERATIONS:-5}"

# ─── Sanity ──────────────────────────────────────────────────────────────────

if ! command -v claude >/dev/null 2>&1; then
    err "claude CLI not on PATH (https://claude.com/claude-code)"
    exit 1
fi
if ! command -v emmylua_check >/dev/null 2>&1; then
    err "emmylua_check not on PATH (run from inside the dev container)"
    exit 1
fi
if [[ ! -d "$BAR/.git" ]]; then
    err "BAR repo not found at $BAR (set BAR_DIR)"
    exit 1
fi

# ─── Workdir ─────────────────────────────────────────────────────────────────

WORKDIR="$(mktemp -d /tmp/bar-llm-XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT
export WORKDIR

step "LLM type-triage workdir: $WORKDIR"
step "Orchestrator model: $ORCHESTRATOR_MODEL"
step "Subagent model: $SUBAGENT_MODEL"
step "Max iterations: $MAX_ITERATIONS"

# ─── Baseline ────────────────────────────────────────────────────────────────

step "Capturing baseline error log..."
(cd "$BAR" && emmylua_check -c .emmyrc.json . 2>&1 || true) > "$WORKDIR/baseline-errors.log"

baseline_count=$(grep -oP '^\s*\K\d+(?= errors?$)' "$WORKDIR/baseline-errors.log" | head -1 || echo 0)
step "Baseline errors: $baseline_count"

if [[ "$baseline_count" == "0" ]]; then
    ok "Already at zero errors — nothing for the orchestrator to do."
    {
        echo "baseline_errors=0"
        echo "final_errors=0"
        echo "iterations=0"
        echo "model_orchestrator=$ORCHESTRATOR_MODEL"
        echo "model_subagent=$SUBAGENT_MODEL"
        date -u +"timestamp=%Y-%m-%dT%H:%M:%SZ"
    } > "$BAR/.git/llm-triage-summary.txt"
    exit 0
fi

# ─── Orchestrator handoff ────────────────────────────────────────────────────

ORCH_PROMPT_FILE="${DEVTOOLS_DIR}/claude/prompts/orchestrator.md"
SUB_PROMPT_FILE="${DEVTOOLS_DIR}/claude/prompts/type-triage-subagent.md"
SKILL_FILE="${DEVTOOLS_DIR}/claude/skills/codemod-prereq/SKILL.md"

for f in "$ORCH_PROMPT_FILE" "$SUB_PROMPT_FILE" "$SKILL_FILE"; do
    if [[ ! -f "$f" ]]; then
        err "Missing orchestrator asset: $f"
        exit 1
    fi
done

step "Handing off to $ORCHESTRATOR_MODEL orchestrator..."

cd "$BAR"

# Inline run-context block is appended to the orchestrator prompt so the
# Opus agent knows where to find chunks, the BAR repo, and the subagent
# prompt template. Heredoc avoids any quoting fights with the prompt body.
PROMPT="$(cat "$ORCH_PROMPT_FILE")

## Run-specific context
- BAR repo: ${BAR}
- Workdir for chunks/results: ${WORKDIR}
- Baseline errors log: ${WORKDIR}/baseline-errors.log
- Baseline error count: ${baseline_count}
- Devtools repo: ${DEVTOOLS_DIR}
- Subagent prompt template: ${SUB_PROMPT_FILE}
- Skill reference: ${SKILL_FILE}
- Orchestrator model: ${ORCHESTRATOR_MODEL}
- Subagent model: ${SUBAGENT_MODEL}
- Max iterations: ${MAX_ITERATIONS}
- Type-check command: \`cd ${DEVTOOLS_DIR} && just bar::check\`
- Subagent dispatch command (per chunk):
    claude --print --model ${SUBAGENT_MODEL} \\
        --permission-mode acceptEdits \\
        --allowedTools \"Read,Edit,Write,Bash,Glob,Grep\" \\
        \"\$(cat ${SUB_PROMPT_FILE} | sed s|CHUNK_PATH|<chunk-file>|g)\"

Begin."

claude --print \
    --model "$ORCHESTRATOR_MODEL" \
    --permission-mode acceptEdits \
    --allowedTools "Read,Edit,Write,Bash,Glob,Grep" \
    "$PROMPT" \
    2>&1 | tee "$WORKDIR/orchestrator.log"

# ─── Final measurement + summary ─────────────────────────────────────────────

step "Capturing post-orchestrator error log..."
(cd "$BAR" && emmylua_check -c .emmyrc.json . 2>&1 || true) > "$WORKDIR/final-errors.log"
final_count=$(grep -oP '^\s*\K\d+(?= errors?$)' "$WORKDIR/final-errors.log" | head -1 || echo 0)

iterations=$(grep -c '^### Iteration' "$WORKDIR/orchestrator.log" 2>/dev/null || echo 0)

{
    echo "baseline_errors=$baseline_count"
    echo "final_errors=$final_count"
    echo "iterations=$iterations"
    echo "model_orchestrator=$ORCHESTRATOR_MODEL"
    echo "model_subagent=$SUBAGENT_MODEL"
    date -u +"timestamp=%Y-%m-%dT%H:%M:%SZ"
} > "$BAR/.git/llm-triage-summary.txt"

# Persist the orchestrator log so the user can inspect it post-run.
cp "$WORKDIR/orchestrator.log" "$BAR/.git/llm-triage-orchestrator.log" 2>/dev/null || true

ok "LLM triage complete: $baseline_count → $final_count errors over $iterations iterations"
