# Proposal

## Why

A turn ends at the first provider error that `api.lua` does not recognise as
retryable. Errors reported *inside* an SSE stream (Anthropic `error`, an
OpenAI/Gemini `{"error":…}` payload) are painted as a banner and end the turn
even though the same request would often succeed seconds later, and a response
cut off by the output-token limit is silently truncated. Today's only retry
loop lives inside a single HTTP request, with a hardcoded `0.5/1.0/2.0 s`
schedule and a hard attempt cap, so a provider that needs a longer wait never
gets one. The result is a session that gives up on hiccups a human would simply
retry.

## What Changes

- **Retry moves to the turn boundary.** `api.stream` performs exactly one
  attempt and reports a *classification* instead of retrying internally. One
  owner of the backoff schedule (the agent turn) replaces the client-level
  loop, so budgets cannot multiply.
- **Catch-all retry.** Any failing attempt is retried by default, including
  mid-stream provider errors, connection drops, HTTP 400/413, credit/payment
  errors (402, "insufficient balance"), and 429/5xx — not just the retryable
  HTTP bodies the client recognises today.
- **Configurable exponential backoff** via a new `retry` config table:
  `base_delay_ms` (2000), `max_delay_ms` (60000), `multiplier` (2),
  `max_failures_at_max_delay` (3). `Retry-After` still overrides the wait.
- **A blacklist that stops the loop**, with an explanation instead of an
  endless retry: permanent failures (invalid API key, model not found,
  unsupported model) and exhausted quota / session limit / budget ("you've hit
  your limit", `insufficient_quota`, "out of budget", suspended accounts).
  Plain pay-as-you-go balance errors stay retryable, because a top-up
  mid-loop can resume them.
- **Auto-continuation on output-token truncation.** A stop with
  `finish_reason`/`stop_reason` `length` / `MAX_TOKENS` is continued with a
  hidden continuation message, uncapped, until the model stops normally or the
  turn's iteration budget runs out. Segments are merged into one assistant
  history entry, so history and resume stay unchanged in shape.
- **Empty-stop recovery.** A turn that ends with no text and no tool calls gets
  exactly one hidden nudge; a second empty stop ends the turn.
- **Abort stays responsive.** Ctrl+C during the backoff wait aborts the turn
  instead of leaving the user waiting for the next attempt.
- **TUI notices.** A dim `retry` row now names the failed attempt, the wait and
  the failure kind; the failed attempt's already-painted rows are discarded
  before the retry row; continuation and give-up notices are dim rows too.
- **Behavior change (defaults).** `retries = 3` leaves the defaults in favour of
  the schedule-based cutoff, so the default retry budget is longer than before
  (up to 8 attempts, ~2 minutes of waiting, bounded by the max-delay cutoff). A
  user-set `retries` still caps the attempts.

No manual command is added: retries, continuations and the cutoff all happen
automatically, and Ctrl+C remains the escape hatch.

## Capabilities

### New Capabilities

- `retry`: error classification (retryable kinds, permanent and quota
  blacklists), the exponential backoff schedule, the max-delay cutoff, and the
  continuation policy (truncation continuation, single empty-stop nudge).

### Modified Capabilities

- `api-client`: `Retry policy`, `Retry-After honored` and `Exhaustion surfaces
  an error` are removed — a stream call is now a single attempt that returns a
  classified failure, no longer emits `error` itself, and marks an attempt
  failed when a provider error arrives mid-stream. Stop reasons are surfaced so
  truncation can be detected.
- `agent-core`: the turn loop gains the retry loop, the abort-interruptible
  wait, attempt tagging on streamed deltas, truncation auto-continuation, the
  empty-stop nudge, and an iteration cap that counts continuation segments.
- `config`: the `retry` defaults and the resolution rules for the new keys
  (including the legacy `retries` cap).
- `tui`: retry/continuation notices, discarding a failed attempt's rows, and
  repainting on retry/continuation without waiting for a keypress.

## Impact

- `src/tether/retry.lua` (new): classification, schedule, cutoff, continuation
  policy — pure Lua, unit-testable without a transport.
- `src/tether/api.lua`: internal retry loop removed; returns
  `ok, failure` with `{message, kind, status, retry_after}`.
- `src/tether/agent.lua`: retry loop and continuation around `api.stream`.
- `src/tether/providers/{openai,anthropic,gemini}.lua`: stop-reason surfacing,
  provider errors fail the attempt.
- `src/tether/config.lua`: `retry` defaults and validation.
- `src/tether/ui.lua`: retry/continuation rows and attempt-aware row discard.
- `Makefile`: the new module joins `LUA_MODS`, the `luac -p` list and the embed
  step.
- `tests/lua_tests.lua`: the T15 client-retry tests are rewritten against the
  new single-attempt contract, plus new tests for classification, the schedule,
  the cutoff and the continuation policy.
