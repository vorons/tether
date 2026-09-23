# context-compaction Specification

## Purpose
LLM-based context compaction: how tether decides to compact, produces a structured summary through the active provider, falls back when the summary request fails, and exposes the manual `/compact [instructions]` path.

## Requirements

### Requirement: Compaction trigger with response reserve
Before each main-loop LLM call the agent SHALL estimate history tokens (length-of-content divided by 4, ceiled). Compaction SHALL run when either estimate exceeds `summarize_at × max_tokens` (defaults 0.7 × 32768) OR estimate exceeds `max_tokens − reserve_tokens` (default reserve 16384), whichever fires first. `reserve_tokens` and `summarize_at` SHALL be readable from `cfg.context`; a missing or non-numeric value SHALL fall back to its default without failing the session.

#### Scenario: Fraction threshold fires
- **WHEN** estimate exceeds 0.7 × max_tokens and is still below max_tokens − reserve_tokens
- **THEN** compaction runs

#### Scenario: Reserve threshold fires first
- **WHEN** estimate exceeds max_tokens − reserve_tokens while still at or below 0.7 × max_tokens (possible when reserve is large relative to max_tokens)
- **THEN** compaction runs

#### Scenario: Malformed reserve falls back
- **WHEN** `context.reserve_tokens` is the string `"lots"`
- **THEN** the reserve default 16384 is used and the session continues

### Requirement: LLM summary replaces the old span
When compaction runs, the agent SHALL keep the system message and the last `keep_recent_messages` messages (default 4; walking back over leading tool messages so a tool result is not orphaned from its call). The messages before that window SHALL be replaced by a single system message whose content is an LLM-generated summary. The summary request SHALL go through the active provider and credential, SHALL use a dedicated one-shot request (not the main turn's retry budget), and SHALL ask for a structured summary covering goal, constraints, progress, key decisions, and next steps. The summary message SHALL be prefixed with a stable marker (e.g. `── summary ──`) so it is recognizable on resume and by `/compact`. Journal history SHALL NOT be rewritten: original journal entries remain; only the in-memory agent history is rewritten.

#### Scenario: Successful LLM compaction
- **WHEN** the threshold fires and the summary request returns non-empty text
- **THEN** history is `[system, summary_system, …keep_recent]`, the summary body is the LLM text, and `context_compressed` is emitted with `mode = "llm"`

#### Scenario: Tool-boundary keep window
- **WHEN** the keep window's first message would be a `tool` role message
- **THEN** the window walks backward so that message stays paired with its assistant tool-call

### Requirement: Compaction fallback on summary failure
If the summary request fails (network error, non-retryable provider failure after the summary call's own single retry, empty output, or abort), the agent SHALL fall back to the truncation summary (each old message cut to 200 chars, newline-joined), rewrite history the same way, and still emit `context_compressed` with `mode = "truncation"`. A compaction failure SHALL NOT emit `error`, SHALL NOT consume the main turn's retry budget, and SHALL NOT prevent the turn from continuing.

#### Scenario: Network failure during summary
- **WHEN** the summary request fails with a connection error
- **THEN** history is rewritten with the truncation summary, `context_compressed` carries `mode = "truncation"`, and the turn proceeds to the next LLM call

#### Scenario: Empty LLM output
- **WHEN** the summary request succeeds but returns empty text
- **THEN** the truncation fallback runs as above

### Requirement: Manual compact with optional instructions
`/compact` SHALL force compaction immediately using the same LLM path (with fallback). The command SHALL accept optional free-text after `/compact` (e.g. `/compact focus on the API contract`); that text SHALL be passed to the summary request as focus instructions. When the summary succeeds the transcript SHALL gain a system row with the summary (or its stable marker when empty); when only the fallback runs the existing `── summary ──` row behavior applies. `/compact` with no history beyond system+keep window SHALL be a no-op that still reports completion without rewriting.

#### Scenario: Compact with focus text
- **WHEN** the user runs `/compact keep the migration plan`
- **THEN** the summary request includes that focus text and the transcript gains a summary row

#### Scenario: Compact is manual and immediate
- **WHEN** the user runs `/compact` while under threshold
- **THEN** compaction runs anyway (manual path ignores the threshold)

### Requirement: Summary request is isolated from turn retry
The one-shot summary request SHALL use at most one automatic retry for transient transport failures and SHALL NOT share the main turn's `retry` state, attempt counters, or `context_compressed` emission with a parallel main-loop attempt. Compaction SHALL NOT run between main-loop retry attempts of the same conversation (existing "no compression between attempts" rule still holds for the main request; the summary request is a separate call made only at the top of the main loop or from `/compact`).

#### Scenario: Main attempt failure does not trigger compaction mid-retry
- **WHEN** a main-loop attempt fails retryably while over threshold
- **THEN** the retry re-sends the same conversation; compaction is not inserted between attempts
