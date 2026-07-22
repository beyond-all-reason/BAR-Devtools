#!/usr/bin/env python3
"""Single-chunk type-triage worker.

One invocation handles one chunk: runs an OpenAI chat loop with two tools
(read_file, edit_file), iterates until the model produces a final text
response or the turn budget is exhausted, then prints the model's
FIXED/ATTEMPTED/UNCATEGORIZED report to stdout.

Invoked by scripts/codemod/llm-type-triage.sh in parallel — one Python process per
chunk. The wrapper bash script handles chunk partitioning, parallel
dispatch, and the before/after emmylua_check measurement.

This file replaced an earlier `llm --functions` heredoc inside the bash
script. Going direct to the openai SDK gives us:

  - Per-turn progress logging (visible in the chunk's log file)
  - Token usage tracking (real input / cached / output counts)
  - Graceful handling of API errors and turn-limit exhaustion (we still
    print whatever final text the model produced last)
  - Tools are normal Python — no shell heredoc encoding, no third-party
    model registry to maintain

Inputs:
    --chunk PATH         file with the inlined chunk error blocks
    --system PATH        file with the system prompt (rules + SKILL.md)
    --model NAME         OpenAI model id (e.g. gpt-5.4-mini)
    --max-turns N        cap on model turns per chunk (default: 50)

Environment:
    BAR_DIR              repo root used to resolve / sandbox tool paths
    OPENAI_API_KEY       OpenAI auth, inherited from CREDENTIALS_RUNNER

Outputs:
    stdout               final FIXED/ATTEMPTED/UNCATEGORIZED report
    stderr               per-turn progress + token summary

Exit codes:
    0    chain ran to completion (or hit turn limit but produced output)
    1    hard failure (auth missing, no progress at all, import error)
"""

import argparse
import json
import os
import sys
from pathlib import Path

try:
    from openai import OpenAI
except ImportError:
    sys.exit(
        "ERROR: openai package not installed. "
        "Install with: python3 -m pip install --user openai"
    )


# ─── Tool sandbox ──────────────────────────────────────────────────────────

BAR = Path(os.environ.get("BAR_DIR", ".")).resolve()
FORBIDDEN_PREFIXES = ("recoil-lua-library/", "types/")
FORBIDDEN_FILES = (".emmyrc.json", ".luarc.json")

# Hard cap on bytes returned for an unbounded read_file. Files above this
# (e.g. luaui/Widgets/gui_pip.lua at 800KB) would otherwise eat the model's
# context once they accumulate in conversation history across turns.
FULL_READ_MAX_BYTES = 60_000


def _resolve(path: str) -> Path:
    """Resolve a relative path against BAR_DIR. Refuses anything that escapes."""
    p = (BAR / path).resolve()
    if not str(p).startswith(str(BAR) + os.sep) and p != BAR:
        raise ValueError("path escapes BAR repo: " + path)
    return p


def _check_writable(path: str) -> str | None:
    """Return an error string if `path` is baseline-managed, else None.

    Important: do NOT use str.lstrip("./") here — it strips any combination
    of '.' and '/' characters and would mangle '.emmyrc.json' into
    'emmyrc.json', bypassing the forbidden-file check entirely."""
    rel = path[2:] if path.startswith("./") else path
    if rel in FORBIDDEN_FILES:
        return f"refusing to edit baseline-managed file: {rel}"
    for prefix in FORBIDDEN_PREFIXES:
        if rel.startswith(prefix):
            return f"refusing to edit out-of-scope path under {prefix}: {rel}"
    return None


# ─── Tool implementations ──────────────────────────────────────────────────

def tool_read_file(path: str, start_line: int = 0, end_line: int = 0) -> str:
    try:
        p = _resolve(path)
        if start_line or end_line:
            lines = p.read_text().splitlines()
            n = len(lines)
            s = max(1, start_line or 1)
            e = min(n, end_line if end_line else n)
            if s > n:
                return f"ERROR: start_line {s} is past end of file ({n} lines)"
            window = lines[s - 1:e]
            width = len(str(e))
            return "\n".join(
                f"{str(s + i).rjust(width)}: {line}"
                for i, line in enumerate(window)
            )
        size = p.stat().st_size
        if size > FULL_READ_MAX_BYTES:
            return (
                f"ERROR: file is {size} bytes (>{FULL_READ_MAX_BYTES}), too large "
                "for an unbounded read. Call read_file(path, start_line, end_line) "
                "with a window around the error line instead (the chunk gives you "
                "exact line numbers)."
            )
        return p.read_text()
    except Exception as e:
        return f"ERROR: {e}"


def tool_edit_file(path: str, search: str, replace: str) -> str:
    err = _check_writable(path)
    if err:
        return f"ERROR: {err}"
    try:
        p = _resolve(path)
        content = p.read_text()
        count = content.count(search)
        if count == 0:
            return "ERROR: search text not found in file (verbatim match required, including whitespace)"
        if count > 1:
            return f"ERROR: search text appears {count} times — expand it for uniqueness"
        p.write_text(content.replace(search, replace, 1))
        return "OK"
    except Exception as e:
        return f"ERROR: {e}"


TOOLS_BY_NAME = {
    "read_file": tool_read_file,
    "edit_file": tool_edit_file,
}

# OpenAI tool schema. Descriptions matter — they're what the model reads to
# decide when and how to call. Keep them in sync with the system prompt.
TOOLS_SCHEMA = [
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": (
                "Read a .lua file from the BAR repo. Path is relative to repo root. "
                "For files larger than ~60KB you MUST pass start_line and end_line "
                "(1-indexed, inclusive) to read just a window — full reads are "
                "rejected for big files because they fill the conversation context "
                "too quickly. The error blocks in your chunk give you the exact line "
                "of every error; read ~20 lines on either side. With line params, "
                "the response is line-number prefixed (e.g. '123: <source>'); strip "
                "the prefix when building search strings for edit_file."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path relative to BAR repo root",
                    },
                    "start_line": {
                        "type": "integer",
                        "description": "1-indexed start line (omit or 0 = full file)",
                    },
                    "end_line": {
                        "type": "integer",
                        "description": "1-indexed inclusive end line (omit or 0 = full file)",
                    },
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "edit_file",
            "description": (
                "Replace the first (and only) occurrence of `search` with `replace` "
                "in `path`. `search` must appear EXACTLY ONCE in the file (verbatim, "
                "including whitespace). If 0 or >1 matches, returns an error and "
                "writes nothing — expand or shrink the search and try again. "
                "Returns 'OK' on success."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Path relative to BAR repo root"},
                    "search": {"type": "string", "description": "Exact substring to find (must be unique)"},
                    "replace": {"type": "string", "description": "Replacement text"},
                },
                "required": ["path", "search", "replace"],
            },
        },
    },
]


# ─── Chat loop ─────────────────────────────────────────────────────────────

def log(msg: str) -> None:
    print(f"[worker] {msg}", file=sys.stderr, flush=True)


def assistant_message_to_dict(msg) -> dict:
    """Convert an OpenAI ChatCompletionMessage into a dict suitable for
    re-sending in the next request. Building this manually rather than
    using model_dump() to avoid emitting fields the API rejects on
    re-send (e.g. `function_call`, `refusal`, `audio`)."""
    out: dict = {"role": "assistant", "content": msg.content}
    if msg.tool_calls:
        out["tool_calls"] = [
            {
                "id": tc.id,
                "type": "function",
                "function": {
                    "name": tc.function.name,
                    "arguments": tc.function.arguments,
                },
            }
            for tc in msg.tool_calls
        ]
    return out


def execute_tool_call(tc) -> str:
    """Run a single tool call and return its string result."""
    name = tc.function.name
    try:
        args = json.loads(tc.function.arguments)
    except json.JSONDecodeError as e:
        return f"ERROR: failed to parse tool args: {e}"
    fn = TOOLS_BY_NAME.get(name)
    if fn is None:
        return f"ERROR: unknown tool: {name}"
    try:
        return fn(**args)
    except TypeError as e:
        return f"ERROR: bad tool arguments: {e}"
    except Exception as e:
        return f"ERROR: tool execution failed: {e}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--chunk", required=True, type=Path,
                    help="file with the inlined chunk error blocks")
    ap.add_argument("--system", required=True, type=Path,
                    help="file with the full system prompt (rules + SKILL.md)")
    ap.add_argument("--model", required=True,
                    help="OpenAI model id, e.g. gpt-5.4-mini")
    ap.add_argument("--max-turns", type=int, default=50,
                    help="cap on model turns per chunk (default: 50)")
    args = ap.parse_args()

    if not os.environ.get("OPENAI_API_KEY"):
        log("ERROR: OPENAI_API_KEY not set in environment")
        return 1
    if not args.chunk.exists():
        log(f"ERROR: chunk file not found: {args.chunk}")
        return 1
    if not args.system.exists():
        log(f"ERROR: system prompt file not found: {args.system}")
        return 1

    chunk_name = args.chunk.stem
    log(f"chunk={chunk_name} model={args.model} max_turns={args.max_turns} BAR_DIR={BAR}")

    system_prompt = args.system.read_text()
    chunk_body = args.chunk.read_text()

    user_msg = (
        f"You are working on chunk: {chunk_name}\n\n"
        "Below are the emmylua_check error blocks assigned to you. Open the .lua "
        "files they reference (paths are relative to the BAR repo root — pass them "
        "straight to read_file / edit_file), fix every error per the rules and fix "
        "priorities in your system prompt, then output the FIXED / ATTEMPTED / "
        "UNCATEGORIZED report as your final message.\n\n"
        "=== chunk errors ===\n"
        f"{chunk_body}\n"
        "=== end chunk ==="
    )

    messages: list[dict] = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_msg},
    ]

    client = OpenAI()

    total_in = 0
    total_cached = 0
    total_out = 0
    final_text: str | None = None
    last_assistant_text: str | None = None
    hit_limit = False

    for turn in range(1, args.max_turns + 1):
        try:
            resp = client.chat.completions.create(
                model=args.model,
                messages=messages,
                tools=TOOLS_SCHEMA,
                parallel_tool_calls=True,
            )
        except Exception as e:
            log(f"turn {turn}: API error: {e}")
            return 1

        usage = getattr(resp, "usage", None)
        if usage is not None:
            total_in += getattr(usage, "prompt_tokens", 0) or 0
            total_out += getattr(usage, "completion_tokens", 0) or 0
            details = getattr(usage, "prompt_tokens_details", None)
            if details is not None:
                total_cached += getattr(details, "cached_tokens", 0) or 0

        msg = resp.choices[0].message
        messages.append(assistant_message_to_dict(msg))
        if msg.content:
            last_assistant_text = msg.content

        tool_calls = msg.tool_calls or []
        if not tool_calls:
            final_text = msg.content or ""
            log(f"turn {turn}: model finished ({len(final_text)} chars of output)")
            break

        # Run all tool calls from this turn (potentially in parallel
        # conceptually — they're independent on the model's side, even
        # though we execute sequentially here for simplicity).
        n_read = sum(1 for tc in tool_calls if tc.function.name == "read_file")
        n_edit = sum(1 for tc in tool_calls if tc.function.name == "edit_file")
        n_other = len(tool_calls) - n_read - n_edit
        parts = []
        if n_read:
            parts.append(f"{n_read} read_file")
        if n_edit:
            parts.append(f"{n_edit} edit_file")
        if n_other:
            parts.append(f"{n_other} other")
        log(f"turn {turn}: {len(tool_calls)} tool calls ({', '.join(parts)})")

        for tc in tool_calls:
            result = execute_tool_call(tc)
            messages.append({
                "role": "tool",
                "tool_call_id": tc.id,
                "content": result,
            })
            # One-line preview per call so the log shows what happened
            # without dumping every byte of every read result.
            if result.startswith("ERROR"):
                log(f"  {tc.function.name} → {result[:120]}")
            elif tc.function.name == "edit_file":
                log(f"  edit_file → {result}")
    else:
        # Loop fell through without break → we exhausted max_turns.
        hit_limit = True
        log(f"hit max-turns limit ({args.max_turns}) without model finalizing")

    log(
        f"tokens: input={total_in} (cached={total_cached}) "
        f"output={total_out} total={total_in + total_out}"
    )

    if final_text:
        print(final_text)
        return 0
    if last_assistant_text:
        log("no clean finish; printing last assistant text:")
        print(last_assistant_text)
        return 0 if hit_limit else 1
    log("no assistant text produced at all")
    return 1


if __name__ == "__main__":
    sys.exit(main())
