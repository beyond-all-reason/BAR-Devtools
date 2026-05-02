#!/usr/bin/env bash
# LLM type-triage: parallel chunked fan-out, single pass, no orchestrator.
#
# Pipeline:
#   1. Capture baseline emmylua_check output
#   2. Parse + group errors by file, partition into ~N chunks
#   3. Spawn N parallel subagents (one per chunk) — each runs the
#      type-triage subagent prompt with its chunk content inlined.
#      Backend is selectable via BACKEND env var:
#        - claude (default): `claude --print` with Read+Edit tools
#        - openai:           scripts/codemod/llm-type-triage-worker.py — a
#                            self-contained Python agent loop using the
#                            openai SDK directly. Sonnet is slow;
#                            gpt-5.4-mini-class models are 10-50x cheaper
#                            and faster. The openai package is auto-
#                            installed via `pip install --user` if missing.
#   4. wait for all
#   5. Re-run emmylua_check, write before/after summary
#
# Design notes:
# - No iteration loop. If a chunk persists after one pass, that's a signal
#   that SKILL.md needs a new category — a human edits the rules and reruns.
#   Iteration on a stable rule set is wasted tokens.
# - No Opus orchestrator. The chunking is deterministic bash+Python; the
#   subagents are independent fan-out workers. No coordinator needed.
# - Subagents only get a Read tool and an Edit tool (no Bash, no shell),
#   which makes the "model misinterprets the prompt as a bash script"
#   failure mode structurally impossible. The OpenAI backend enforces this
#   by only exposing read_file/edit_file in its Python tool sandbox.
# - The OpenAI variant relies on automatic prompt caching: SKILL.md +
#   subagent rules go in the system message (identical across all parallel
#   chunks) so the prefix is cached after the first chunk warms it up.
#   Within a chunk, accumulated read_file results are also cached on every
#   turn after they first appear, keeping multi-turn cost roughly linear.
# - The OpenAI agent loop lives in scripts/codemod/llm-type-triage-worker.py
#   (separate file, not a heredoc) so it's testable, lintable, and easy
#   to debug. The bash script just dispatches one Python process per chunk.
#
# Inputs (env, with defaults):
#   DEVTOOLS_DIR   -- BAR-Devtools repo root (auto-detected)
#   BAR_DIR        -- BAR repo (default: $DEVTOOLS_DIR/Beyond-All-Reason)
#   BACKEND        -- claude | openai (default: claude)
#   SUBAGENT_MODEL -- Model name. Default depends on BACKEND:
#                       claude  → claude-sonnet-4-6
#                       openai  → gpt-5.4-mini
#   TARGET_CHUNKS  -- Number of partitions (default: 8)
#   CHAIN_LIMIT    -- (openai only) max model turns per chunk before the
#                     worker prints partial output and exits (default: 50)
#   CLAUDE_BIN_OVERRIDE  -- absolute path to claude (skip discovery)
#   EMMYLUA_BIN_OVERRIDE -- absolute path to emmylua_check (skip discovery)
#   OPENAI_API_KEY -- (openai only) inherited from CREDENTIALS_RUNNER wrap

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

# Run a command on the host OS from inside a distrobox container.
host_exec() {
    if [ -f /run/.containerenv ] && command -v distrobox-host-exec &>/dev/null; then
        distrobox-host-exec "$@"
    else
        "$@"
    fi
}

BACKEND="${BACKEND:-claude}"
case "$BACKEND" in
    claude) DEFAULT_MODEL="claude-sonnet-4-6" ;;
    openai) DEFAULT_MODEL="gpt-5.4-mini" ;;
    *)
        err "Unknown BACKEND: $BACKEND (expected: claude | openai)"
        exit 1
        ;;
esac
SUBAGENT_MODEL="${SUBAGENT_MODEL:-$DEFAULT_MODEL}"
TARGET_CHUNKS="${TARGET_CHUNKS:-8}"
# Each turn the model can request multiple parallel tool calls, so 50 turns
# is plenty of headroom for a 30-error chunk *if the model batches*. Bumped
# from 25 after chunk-04 (29 errors, several files >60KB requiring multiple
# small line-range reads) hit the limit doing one-at-a-time tool calls.
CHAIN_LIMIT="${CHAIN_LIMIT:-50}"

# ─── Resolve binaries ────────────────────────────────────────────────────────

resolve_emmylua() {
    if [[ -n "${EMMYLUA_BIN_OVERRIDE:-}" ]]; then echo "$EMMYLUA_BIN_OVERRIDE"; return 0; fi
    local c
    for c in /usr/local/bin/emmylua_check "$HOME/.local/bin/emmylua_check" /usr/bin/emmylua_check; do
        [[ -x "$c" ]] && { echo "$c"; return 0; }
    done
    command -v emmylua_check 2>/dev/null || true
}
EMMYLUA_BIN="$(resolve_emmylua)"
if [[ -z "$EMMYLUA_BIN" ]]; then
    err "emmylua_check not found"
    err "  override: EMMYLUA_BIN_OVERRIDE=/abs/path/to/emmylua_check"
    exit 1
fi

resolve_host_claude() {
    if [[ -n "${CLAUDE_BIN_OVERRIDE:-}" ]]; then echo "$CLAUDE_BIN_OVERRIDE"; return 0; fi
    local c
    for c in "$HOME/.local/bin/claude" "$HOME/.npm-global/bin/claude" "$HOME/.bun/bin/claude" \
             /home/linuxbrew/.linuxbrew/bin/claude /usr/local/bin/claude /usr/bin/claude; do
        host_exec test -x "$c" && { echo "$c"; return 0; }
    done
    host_exec which claude 2>/dev/null || true
}

# Lazily install the openai Python SDK if missing. We deliberately do NOT
# add this to the global setup script — only users who pick BACKEND=openai
# pay the install cost. The install goes via `pip --user` so it lands in
# the user's site-packages without needing root.
ensure_openai_sdk() {
    if python3 -c 'import openai' 2>/dev/null; then
        return 0
    fi
    step "openai SDK not found — installing via pip --user (one-time, BACKEND=openai only)..."
    if ! python3 -m pip install --user --quiet openai; then
        err "pip install --user openai failed"
        err "  manual install:  python3 -m pip install --user openai"
        exit 1
    fi
    if ! python3 -c 'import openai' 2>/dev/null; then
        err "Installed openai but Python still can't import it. Check pyenv setup."
        exit 1
    fi
    ok "Installed openai SDK"
}

# Resolve worker binary / dependencies based on BACKEND.
case "$BACKEND" in
    claude)
        CLAUDE_HOST_BIN="$(resolve_host_claude)"
        if [[ -z "$CLAUDE_HOST_BIN" ]]; then
            err "claude CLI not found on host"
            err "  override: CLAUDE_BIN_OVERRIDE=/abs/path/to/claude"
            exit 1
        fi
        WORKER_BIN_DESC="claude:        $CLAUDE_HOST_BIN"
        ;;
    openai)
        if [[ -z "${OPENAI_API_KEY:-}" ]]; then
            err "BACKEND=openai but OPENAI_API_KEY is not set"
            err "  Wrap your invocation with CREDENTIALS_RUNNER (see just/bar.just),"
            err "  e.g.  CREDENTIALS_RUNNER='op run --env-file=~/code/ai.env.op --'"
            exit 1
        fi
        ensure_openai_sdk
        OPENAI_WORKER="${DEVTOOLS_DIR}/scripts/codemod/llm-type-triage-worker.py"
        if [[ ! -x "$OPENAI_WORKER" ]]; then
            err "OpenAI worker script not found or not executable: $OPENAI_WORKER"
            exit 1
        fi
        WORKER_BIN_DESC="worker:        $OPENAI_WORKER"
        ;;
esac

# PATH passed to claude on the host so its tool subprocesses can find
# the emmylua_check wrapper at ~/.local/bin (distrobox-host-exec strips PATH).
HOST_RUN_PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

if [[ ! -d "$BAR/.git" ]]; then
    err "BAR repo not found at $BAR"
    exit 1
fi

step "emmylua_check: $EMMYLUA_BIN"
step "$WORKER_BIN_DESC"
step "backend:       $BACKEND"
step "model:         $SUBAGENT_MODEL"
step "chunks:        $TARGET_CHUNKS (target)"
[[ "$BACKEND" == "openai" ]] && step "chain limit:   $CHAIN_LIMIT"

# ─── Workdir ─────────────────────────────────────────────────────────────────

WORKDIR="$(mktemp -d /tmp/bar-llm-XXXXXX)"
PRESERVE_DIR="$BAR/.git/llm-triage"

# On exit (success OR failure), copy whatever logs/chunks we have into the
# BAR repo's .git/ directory so the user can inspect them post-mortem. This
# matters for early-exit cases where we never reach the post-triage code path.
preserve_and_cleanup() {
    if [[ -d "$WORKDIR" ]]; then
        rm -rf "$PRESERVE_DIR"
        mkdir -p "$PRESERVE_DIR"
        cp -r "$WORKDIR"/* "$PRESERVE_DIR/" 2>/dev/null || true
        rm -rf "$WORKDIR"
    fi
}
trap preserve_and_cleanup EXIT
export WORKDIR
mkdir -p "$WORKDIR/chunks" "$WORKDIR/logs"

# ─── Baseline ────────────────────────────────────────────────────────────────

step "Capturing baseline error log..."
(cd "$BAR" && "$EMMYLUA_BIN" -c .emmyrc.json . 2>&1 || true) > "$WORKDIR/baseline-errors.log"

baseline_count=$(grep -oP '^\s*\K\d+(?= errors?$)' "$WORKDIR/baseline-errors.log" | head -1 || echo 0)
step "Baseline errors: $baseline_count"

write_summary() {
    local final="$1" chunks="$2"
    {
        echo "baseline_errors=$baseline_count"
        echo "final_errors=$final"
        echo "chunks=$chunks"
        echo "model=$SUBAGENT_MODEL"
        date -u +"timestamp=%Y-%m-%dT%H:%M:%SZ"
    } > "$BAR/.git/llm-triage-summary.txt"
}

if [[ "$baseline_count" == "0" ]]; then
    ok "Already at zero errors — nothing to triage."
    write_summary 0 0
    exit 0
fi

# ─── Chunk by file ───────────────────────────────────────────────────────────

step "Partitioning errors into ~$TARGET_CHUNKS chunks (grouped by file)..."

CHUNK_COUNT=$(python3 - "$WORKDIR/baseline-errors.log" "$WORKDIR/chunks" "$TARGET_CHUNKS" <<'PY'
import sys, re, math
from pathlib import Path

log_path, out_dir, target_chunks = sys.argv[1], Path(sys.argv[2]), int(sys.argv[3])
text = Path(log_path).read_text()

# emmylua_check emits per-diagnostic blocks like:
#
#   error: msg [code]
#     --> file:line:col
#
#     <source context>
#
#   warning: msg [code]
#     --> ...
#
#   --- path/to/file.lua [N warnings, M hints]   ← section summary header
#
# Walk *boundaries* (severity-prefixed lines OR `---` section headers) and
# keep only blocks that start with `error:`. Naive `re.split(r'\n(?=error:)')`
# glues intervening warnings AND section headers onto the preceding error
# block, inflating chunks by orders of magnitude.
BOUNDARY_RE = re.compile(r'^(?:error|warning|info|note|hint):|^---\s', re.MULTILINE)
positions = [m.start() for m in BOUNDARY_RE.finditer(text)]
positions.append(len(text))

blocks = []
for i in range(len(positions) - 1):
    block = text[positions[i]:positions[i + 1]].rstrip()
    if block.startswith('error:'):
        blocks.append(block)

by_file = {}
for block in blocks:
    m = re.search(r'-->\s+([^\s:]+):', block)
    if not m:
        continue
    by_file.setdefault(m.group(1), []).append(block)

if not by_file:
    print(0, end='')
    sys.exit(0)

total_errors = sum(len(v) for v in by_file.values())
target_per_chunk = max(1, math.ceil(total_errors / target_chunks))
hard_cap = int(target_per_chunk * 1.5)

# Greedy bin-pack: sort files alphabetically (determinism), accumulate
# until we'd exceed hard_cap, then start a new chunk. Files are atomic.
chunks, current, current_size = [], [], 0
for f in sorted(by_file.keys()):
    n = len(by_file[f])
    if current_size > 0 and current_size + n > hard_cap:
        chunks.append(current)
        current, current_size = [], 0
    current.append(f)
    current_size += n
if current:
    chunks.append(current)

out_dir.mkdir(parents=True, exist_ok=True)
for i, files in enumerate(chunks, 1):
    with (out_dir / f'chunk-{i:02d}.txt').open('w') as fh:
        for f in files:
            for block in by_file[f]:
                fh.write(block + '\n\n')

print(len(chunks), end='')
PY
)

if [[ -z "$CHUNK_COUNT" || "$CHUNK_COUNT" == "0" ]]; then
    err "Chunker produced 0 chunks but baseline shows $baseline_count errors"
    err "Check the log format at $WORKDIR/baseline-errors.log"
    exit 1
fi

step "Wrote $CHUNK_COUNT chunk files to $WORKDIR/chunks/"
for c in "$WORKDIR/chunks/"chunk-*.txt; do
    n=$(grep -c '^error:' "$c" 2>/dev/null || echo 0)
    info "  $(basename "$c"): $n errors"
done

# ─── Fan-out: spawn parallel subagents ───────────────────────────────────────

# Pick the prompt file matching the backend. The two prompts share most of
# their content (rules, fix priorities, output format) but differ in the
# tool surface they describe to the model.
case "$BACKEND" in
    claude) SUB_PROMPT_FILE="${DEVTOOLS_DIR}/claude/prompts/type-triage-subagent.md" ;;
    openai) SUB_PROMPT_FILE="${DEVTOOLS_DIR}/claude/prompts/type-triage-subagent-openai.md" ;;
esac
if [[ ! -f "$SUB_PROMPT_FILE" ]]; then
    err "Missing subagent prompt: $SUB_PROMPT_FILE"
    exit 1
fi

dispatch_claude_chunk() {
    local chunk_path="$1" log_path="$2" chunk_name="$3"

    # Substitute CHUNK_PATH placeholder in the subagent prompt template.
    local prompt
    prompt="$(sed "s|CHUNK_PATH|${chunk_path}|g" "$SUB_PROMPT_FILE")"

    # Subagents only need Read + Edit. No Bash means the "claude
    # misinterprets prompt as a script to debug" failure mode is
    # structurally impossible.
    #
    # The `--` separator is REQUIRED before "$prompt". Without it,
    # claude's argparse consumes the positional prompt as an extra
    # value to the preceding `--allowedTools` flag and then complains
    # that no prompt was provided. (Reproducible: any `--allowedTools
    # "X,Y" "<prompt>"` invocation fails the same way.)
    host_exec env "PATH=$HOST_RUN_PATH" "HOME=$HOME" \
        "$CLAUDE_HOST_BIN" --print \
            --model "$SUBAGENT_MODEL" \
            --permission-mode acceptEdits \
            --allowedTools "Read,Edit" \
            -- "$prompt" \
        > "$log_path" 2>&1 &
}

dispatch_openai_chunk() {
    local chunk_path="$1" log_path="$2" chunk_name="$3"

    # The Python worker owns the agent loop, the tool sandbox, and the
    # token accounting. We just hand it the inputs and capture stdout/
    # stderr into the log file. BAR_DIR is exported so the worker's
    # tools resolve paths against the right repo; OPENAI_API_KEY is
    # inherited from the CREDENTIALS_RUNNER wrap on the parent process.
    BAR_DIR="$BAR" python3 "$OPENAI_WORKER" \
        --chunk "$chunk_path" \
        --system "$OPENAI_SYSTEM_PROMPT_FILE" \
        --model "$SUBAGENT_MODEL" \
        --max-turns "$CHAIN_LIMIT" \
        > "$log_path" 2>&1 &
}

# Build the openai system prompt once: the prompt file + the full SKILL.md
# reference, concatenated into a tmp file inside WORKDIR. This block is
# identical across all parallel chunks → after the first chunk's first
# turn lands, every other chunk's turn hits OpenAI's prompt cache for the
# shared prefix and pays roughly half price on it. The tmp file is
# preserved alongside the logs by the EXIT trap.
if [[ "$BACKEND" == "openai" ]]; then
    SKILL_MD="${DEVTOOLS_DIR}/claude/skills/codemod-prereq/SKILL.md"
    if [[ ! -f "$SKILL_MD" ]]; then
        err "Missing SKILL.md: $SKILL_MD"
        exit 1
    fi
    OPENAI_SYSTEM_PROMPT_FILE="$WORKDIR/openai-system-prompt.txt"
    {
        cat "$SUB_PROMPT_FILE"
        printf '\n\n---\n\n# SKILL.md (canonical fix procedures)\n\n'
        cat "$SKILL_MD"
    } > "$OPENAI_SYSTEM_PROMPT_FILE"
fi

step "Dispatching $CHUNK_COUNT subagents in parallel ($BACKEND backend)..."
cd "$BAR"

pids=()
for chunk_path in "$WORKDIR/chunks/"chunk-*.txt; do
    chunk_name="$(basename "$chunk_path" .txt)"
    log_path="$WORKDIR/logs/${chunk_name}.log"

    case "$BACKEND" in
        claude) dispatch_claude_chunk "$chunk_path" "$log_path" "$chunk_name" ;;
        openai) dispatch_openai_chunk "$chunk_path" "$log_path" "$chunk_name" ;;
    esac

    pids+=($!)
    info "  spawned $chunk_name (pid $!)"
done

step "Waiting for $CHUNK_COUNT subagents..."
# NB: do NOT use `((fail_count++))` here — that returns the pre-increment
# value as its exit status, so when fail_count is 0 the expression's status
# is 0 (failure under set -e), aborting the script before the warn fires
# and before we can preserve the logs. Use $(( )) substitution instead.
fail_count=0
for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
        warn "  subagent pid $pid exited non-zero"
        fail_count=$((fail_count + 1))
    fi
done

if [[ "$fail_count" -gt 0 ]]; then
    warn "$fail_count of $CHUNK_COUNT subagents reported failure (continuing)"
fi
ok "All subagents finished"

# ─── Final measurement ───────────────────────────────────────────────────────

step "Capturing post-triage error log..."
(cd "$BAR" && "$EMMYLUA_BIN" -c .emmyrc.json . 2>&1 || true) > "$WORKDIR/final-errors.log"
final_count=$(grep -oP '^\s*\K\d+(?= errors?$)' "$WORKDIR/final-errors.log" | head -1 || echo 0)

write_summary "$final_count" "$CHUNK_COUNT"

# Logs are preserved by the EXIT trap (preserve_and_cleanup), so no copy
# needed here. Trap fires unconditionally — even on early exits — so a
# crashed run is just as inspectable as a successful one.

ok "LLM triage complete: $baseline_count → $final_count errors over $CHUNK_COUNT chunks"
