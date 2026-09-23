# Design

## Context

Compaction lives at `agent.lua` (`should_summarize` / `compress_history`): a pure truncation that keeps system + last 4 and joins old messages at 200 chars each. `/compact` goes through `commands.compact()` → the same function. The transport is a single streaming entry (`api.stream`) with retry owned by the main turn loop; there is no one-shot non-stream helper yet. Threshold is only `summarize_at × max_tokens` — no reserve for the reply. See proposal.md for motivation.

## Goals / Non-Goals

**Goals:**
- Structured LLM summary as the primary compaction body; truncation as reliable fallback.
- Reserve-aware trigger so the reply has headroom.
- Manual `/compact [instructions]` with focus text.
- Summary request isolated from the main turn's retry state.

**Non-Goals:**
- Rewriting the session journal or making compaction durable across resume beyond the existing in-memory rewrite.
- Branch/tree summaries (no session tree yet).
- A separate compaction model or per-model token budgets (defer until multi-model config needs it).
- Streaming the summary into the transcript as it generates (one-shot text is enough).

## Decisions

1. **One-shot summary via existing `api.stream` (accumulate `text_delta`)**  
   Rationale: reuses provider adapters, auth header-file path, and SSE parsing; no new transport. Alternative (non-stream REST per provider) would touch all three adapters for little gain. The summary call passes a dedicated messages array (system summary prompt + serialized old span) and ignores tool schemas.

2. **Trigger: `estimate > min(summarize_at×max, max−reserve)` is wrong; use OR of two thresholds**  
   Actually fire when `estimate > summarize_at×max` **OR** `estimate > max−reserve`. With defaults (0.7×32768=22937, 32768−16384=16384) the reserve threshold is lower and effectively dominates — which is intentional (reserve is the safety net; fraction remains for users who shrink reserve). Alternative (AND) would never fire reserve alone. Document that reserve can make effective threshold lower than `summarize_at`.

3. **Keep window from config `context.keep_recent_messages` (default 4)**  
   Same algorithm as today (walk back over leading `tool` messages). Pure default keeps old configs working.

4. **Summary failure → truncation fallback, never `error`**  
   Compaction must not strand the turn. Single extra transport retry inside the summary helper only; any further failure falls back. `context_compressed.mode` labels the path for the UI/tests.

5. **`/compact` reuses the same `compact_with(cfg, api_key, focus)` entry**  
   Commands layer passes optional focus string; threshold bypass is a boolean. Transcript row rendering stays in `ui`/`transcript` as today.

6. **Serialization of the old span for the summary prompt**  
   Role-prefixed lines, tool results truncated (e.g. 2000 chars) to keep the summary request bounded — mirrors common practice and avoids feeding megabytes of file reads into the summary call.

## Risks / Trade-offs

- [Summary request costs an extra LLM call and can stall the loop briefly] → Bound output tokens; fall back on timeout/failure; show existing waiting spinner via a synthetic event if needed.
- [Reserve default 16384 may compact earlier than users expect on 32k models] → Document in config spec; fraction threshold still present for tuning.
- [LLM summary may omit tool-call pairing context] → Keep window already protects the tail; summary prompt explicitly asks for progress/decisions.
- [Double compaction in one turn (auto then manual)] → Manual `/compact` is explicit; auto path only at top of main loop as today.

## Migration Plan

1. Land config keys + trigger change (behavior still truncation if LLM path disabled by failure).
2. Land summary helper + wiring + `mode` on event.
3. Land `/compact` focus argument.
4. Rollback: any failure degrades to truncation fallback — no config flag required for emergency disable; optional `context.compact_llm = false` can be added if needed later (not in this change).

## Open Questions

- None blocking. Whether to journal a `summary` event type for the LLM body (visible on resume) is deferred: current resume already rebuilds from journal messages, and the rewritten history is not journaled — same as today's truncation. If resume loses the summary, that is pre-existing behavior, not introduced here.
