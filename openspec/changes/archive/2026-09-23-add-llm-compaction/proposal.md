# Proposal

## Why

Context compaction today is a pure truncation heuristic (`len/4` estimate, keep system + last 4, each old message cut to 200 chars): long sessions lose decisions and constraints that the model still needs, and there is no reserve for the model's reply — the threshold can fire when the next answer itself will not fit.

## What Changes

- Replace the inline truncation summary with an **LLM-generated summary** (one-shot request through the existing provider adapter) that preserves goal, constraints, progress, key decisions, and next steps.
- Add a **response reserve**: auto-compaction triggers when `estimate > max_tokens − reserve_tokens` (and keep the existing `summarize_at` fraction as an alternative trigger), so the reply has headroom.
- Add config knobs under `context`: `reserve_tokens` (default 16384), `keep_recent_messages` (default 4), `compact_max_output_tokens` (optional cap for the summary request).
- `/compact [instructions]` accepts optional free-text focus for the summary; auto-compaction uses the default structured prompt.
- On LLM failure (network, provider error, empty summary), fall back to today's truncation summary and still emit `context_compressed` — compaction never blocks a turn.
- Emit `context_compressed` with an optional `mode` field (`llm` | `truncation`) so the transcript can label the summary source.

## Capabilities

### New Capabilities

- `context-compaction`: LLM-based history summarization, reserve-aware trigger, fallback behavior, and the manual `/compact` contract.

### Modified Capabilities

- `agent-core`: the existing "Context compression at threshold" requirement is replaced — trigger uses reserve-aware budget, summary body comes from an LLM call when available, truncation becomes the fallback path.
- `config`: new `context.*` keys with defaults; existing `summarize_at` keeps its meaning as a fractional trigger.
- `tui`: `/compact` accepts an optional argument; the `context_compressed` transcript line may show the LLM summary snippet.

## Impact

- Code: `src/tether/agent.lua` (compress path), `src/tether/commands.lua` (`compact`), `src/tether/api.lua` (one-shot non-stream or streamed summarize call), `src/tether/config.lua` (defaults), `src/tether/transcript.lua` / `ui.lua` (event rendering), `src/tether/providers/*` (minimal — reuse `stream` or add a non-stream helper).
- Tests: `tests/lua_tests.lua` compression block; new fixtures for LLM-success and LLM-fallback.
- Sessions: journal unchanged (compression remains in-memory history rewrite; original journal entries stay).
- Dependencies: none new (existing libcurl transport).
