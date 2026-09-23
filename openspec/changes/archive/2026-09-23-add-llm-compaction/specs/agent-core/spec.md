# Spec Delta

## MODIFIED Requirements

### Requirement: Context compression at threshold
Before each LLM call, the agent SHALL estimate history tokens (length-of-content divided by 4, ceiled). When the estimate exceeds `summarize_at × max_tokens` (defaults 0.7 × 32768) **or** exceeds `max_tokens − reserve_tokens` (default reserve 16384), whichever fires first, the agent SHALL compact: keep the system message and the last `keep_recent_messages` messages (default 4, walking back over leading tool messages so a tool result is not orphaned from its call), replace the rest with a single system message whose content is an LLM-generated structured summary (goal, constraints, progress, key decisions, next steps) obtained through the active provider in a one-shot request isolated from the main turn's retry budget. On summary-request failure or empty output the agent SHALL fall back to the previous truncation summary (200 chars per old message) and SHALL still emit `context_compressed`. The event SHALL carry `mode` (`"llm"` or `"truncation"`). Journal entries SHALL NOT be rewritten.

#### Scenario: Threshold crossed
- **WHEN** estimated tokens exceed 0.7 × max_tokens
- **THEN** the history is rewritten as described and the UI receives
  a `context_compressed` event

#### Scenario: Threshold crossed with successful summary
- **WHEN** estimated tokens exceed 0.7 × max_tokens and the summary request returns text
- **THEN** the history is rewritten with the LLM summary as a marked system message, the UI receives `context_compressed` with `mode = "llm"`, and the keep window preserves tool-call/result pairing

#### Scenario: Threshold crossed with failed summary
- **WHEN** estimated tokens exceed the threshold and the summary request fails
- **THEN** history is rewritten with the truncation fallback, `context_compressed` carries `mode = "truncation"`, no `error` event is emitted for the summary failure, and the turn continues

#### Scenario: Reserve threshold fires
- **WHEN** estimated tokens exceed `max_tokens − reserve_tokens` while still at or below `summarize_at × max_tokens`
- **THEN** compaction runs the same as when the fraction threshold fires

#### Scenario: No compression between main attempts
- **WHEN** an attempt fails retryably and the history is over the summarization threshold
- **THEN** the retry re-sends the same conversation, uncompressed (the summary request is not inserted between attempts)
