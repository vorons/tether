# Design

## Context

See proposal.md — Why. Current state that shapes the approach:

- `src/tether/api.lua` owns the only retry loop today: `http_request`
  recurses on a transport failure or a "retryable body", sleeping a
  hardcoded `0.5/1.0/2.0 s` and stopping at `cfg.retries` (default 3).
  It emits `retry` events itself and surfaces `API failed after N
  attempts` as an `error` event.
- A provider error reported *inside* an SSE stream is not a failure at
  all to that loop: `providers/openai.lua` and `providers/gemini.lua`
  emit an `error` event and let the call succeed, while
  `providers/anthropic.lua` emits one and keeps parsing. `agent.lua`
  forwards the event to the UI and returns success.
- `agent.main_loop` treats `api.stream` returning false as terminal: it
  returns false and the turn ends with the error banner.
- Stop reasons are discarded. `openai.lua` only looks for
  `finish_reason == "stop"` (to emit `done`); Anthropic reads
  `message_delta` for usage only; Gemini never parses `finishReason`.
- Constraints from the project's own conventions: no `load`, no external
  process for HTTP, all agent logic in Lua (`docs/decisions/`), new
  modules must be added to the Makefile's `LUA_MODS`, `luac -p` list and
  `tools/embed.lua` arguments, and unit tests run under plain `lua`
  (`tests/lua_tests.lua`) against pure modules or the `host_mock`
  transport. The TUI repaints on events and keypresses only — it has no
  background timer.

## Goals / Non-Goals

**Goals:**

- Exactly one component owns the backoff schedule and the failure
  budget, so two layers can never sleep twice for the same failure.
- Classification that is pure data in → kind out, so it is testable
  without a transport mock and extendable in one place.
- A retry loop that can be interrupted at any point, including during a
  60-second wait.
- Continuations that leave history, the journal and resume in exactly
  the shape a single uninterrupted answer would have.

**Non-Goals:**

- An extension or plugin seam (pi's extension model has no analogue in
  a single-binary agent with all logic embedded).
- A manual retry command; automatic only.
- Resuming a partially consumed stream: a retry re-sends the whole
  request, as pi-retry does.
- Replaying or preserving the output of a failed attempt.
- Changing when compaction happens, beyond "a retry must not compress".

## Decisions

### 1. Move the retry loop to the agent turn; `api.stream` makes one attempt

`api.stream(cfg, key, messages, on_event)` becomes a single-attempt call
returning `ok, failure`, where `failure = { message, kind, status,
retry_after }`. It never sleeps, never repeats, and never emits `error`
or `retry`. `agent.main_loop` owns the loop: it calls the transport,
asks `retry` for a verdict, waits, and calls again with the same
history.

*Why:* a mid-stream provider error is only observable as a failed
*attempt*, so the loop has to sit above one whole request. Keeping the
client's loop as well would give every failure two independent budgets
and interleave two sleep schedules; pi-retry makes the same call by
disabling pi's native scheduler while it is loaded.

*Alternatives considered:* (a) keep the client loop and add a turn-level
loop on top — two schedules, doubled waiting, and the client's own
`error` event would fire for a failure the turn is about to retry;
(b) retry inside the transport (`http_stream`) — still one HTTP call, so
a provider error chunk and a truncated answer remain invisible.

### 2. A new pure module `src/tether/retry.lua` holds the policy

Classification, the schedule, the cutoff arithmetic, and the
continuation decisions live in `retry.lua` as pure functions over
strings and numbers. `agent.lua` applies them; `api.lua` only reports
status, text and `retry_after`.

*Why:* `providers/common.lua` already establishes the "pure module,
loaded by the binary and by the tests" pattern, and the classification
table is exactly the kind of thing that needs a test per pattern without
a mocked socket.

*Alternatives considered:* classification in `api.lua` (needs the HTTP
mock to test, and the turn loop would import a transport module for
policy), or inline in `agent.lua` (agent.lua is already 681 lines and
the loop is not the place for a pattern table).

### 3. Classification: quota → permanent → retryable, catch-all retryable

Pattern lists are matched case-insensitively against the failure text,
with an optional HTTP status. Quota and permanent matches stop the loop;
everything else is retryable, and an unmatched failure is `unknown`,
which is retryable. The pattern set is adapted from pi-retry's
documented patterns, plus the status inference `api.lua` already does in
`is_retryable_body` (empty body, 429/5xx). The pay-as-you-go distinction
is preserved: `insufficient balance` / `insufficient credits` / HTTP 402
stay retryable because a top-up can resume them, while session limits,
plan quotas and budgets do not self-resolve.

*Alternatives considered:* a strict allow-list (any new provider error
would silently end the turn — the failure mode this change exists to
remove), or retry-everything with no blacklist (a bad API key would be
retried for two minutes before the obvious error appears).

### 4. A failure is returned, not emitted

Because only the loop knows whether a failure is terminal, `api.stream`
returns it and the loop decides. A failed attempt that will be retried
emits a `retry` event; only the terminal failure emits an `error`.

*Why:* the current code path emits `error` from the transport, which is
why an attempt that is about to succeed on retry currently paints an
error banner. Moving the decision up makes that structurally impossible.

*Alternatives considered:* emit `error` with a `retryable` flag and let
the UI suppress it — pushes policy into the renderer and makes the
banner's meaning depend on a field the UI must interpret.

### 5. Configuration: a nested `retry` table, legacy `retries` as a cap

```lua
retry = {
  base_delay_ms = 2000,
  max_delay_ms = 60000,
  multiplier = 2,
  max_failures_at_max_delay = 3,
  -- max_attempts = 5, -- optional hard cap; absent = cutoff only
}
```

The keys are named after pi-retry's semantics but grouped the way this
project groups related settings (`ui`, `context`, `tools`, `providers`).
A legacy top-level `retries` keeps working as `retry.max_attempts`, and
the defaults no longer carry `retries = 3`, so the default budget is the
schedule cutoff rather than a fixed attempt count.

*Alternatives considered:* flat `retry_base_delay_ms` keys (inconsistent
with every other grouped setting), or only extending `retries` to a table
(reuses a key whose old meaning was an attempt count — ambiguous).

### 6. Continuations merge into one assistant answer; the hidden message is transient

A continuation is appended to history as a `user`-role message (so no
provider sees a trailing assistant message) with a fixed instruction to
resume without repeating. When the segment completes, its text is
appended to the answer so far and the hidden message is removed from
history; the merged answer is journaled once, as a single assistant
message. If the turn ends early, the text accumulated so far is still
journaled.

*Why:* removing the hidden message keeps history in the shape a normal
turn would have, which matters beyond tidiness — Anthropic rejects two
consecutive assistant messages, so a resumed session whose journal
contained an unmerged segment pair would fail on its first request.

*Alternatives considered:* one assistant entry per segment plus a
journaled `hidden` flag — works, but threads a new field through the
journal, resume, and transcript restore for no user-visible gain.
Mutating the system prompt instead of adding a message — the composed
prompt is built once per session and stored as `history[1]`, so
rewriting it would rewrite the session's identity.

### 7. Empty stop: one nudge, then an `error` with kind `empty`

An empty answer gets exactly one hidden nudge with no backoff wait. If
the nudged attempt is empty too, the turn ends with an `error` event
(kind `empty`) rather than a silent success, which also lines up with
`--print`'s existing "no response text" contract.

*Why:* pi nudges once because retrying an empty response in place does
not help — the model has already decided it is finished — and the second
empty answer is a real failure the user needs to see.

### 8. Attempt tagging for precise row discard

`text_delta` and `reasoning_delta` carry `attempt` (1-based), and the
`retry` event names the attempt that failed. The TUI records the attempt
on each row it paints and drops that attempt's rows when the retry
arrives.

*Why:* a turn may already hold tool rows and text from earlier
iterations of the same turn; "drop everything after the last user row"
would delete rows the user wants to keep.

*Alternatives considered:* a `discard` event carrying a row count — the
TUI would have to trust a number that can drift; the attempt tag is
self-describing.

### 9. Abort responsiveness during a wait

The wait sleeps in slices of at most 250 ms, checking `abort_requested`
between slices; an abort emits `aborted` and stops the loop.

*Why:* a single `tether.sleep(60)` would ignore Ctrl+C for a minute,
turning the new longer backoff into a responsiveness regression.

### 10. Stop-reason plumbing per provider

Each provider remembers the last stop reason it saw for the current
request and repeats it on every `done` for that request: OpenAI maps
`finish_reason` (and keeps it across the later `[DONE]` sentinel),
Anthropic stores the `message_delta` reason and reports it at
`message_stop`, Gemini parses `finishReason` and reports it from
`stream_finished` / `handle_non_sse`, which is where its `done` is
produced.

*Why:* the sentinel and the clean EOF carry no reason of their own, and
`done` events are already emitted from several places per request; the
agent only needs the *answer's* reason, and it must not be cleared by the
last no-reason terminator.

### 11. The host delivers the interrupt while a turn blocks

The host watches stdin while it blocks a turn — inside `tether.sleep` and in
libcurl's progress callback — turns byte `0x03` into an interrupt flag
(`tether.abort_requested()` read-and-clear, `tether.clear_abort()`), and queues
every other byte for `tether.read_char`. `tether.sleep` uses a poll with a
bounded timeout, so input wakes it instead of waiting out the backoff.

*Why:* raw mode clears ISIG, so Ctrl+C is a byte, and the key handler runs
inside the same call as `agent.turn` — meaning nothing reads that byte for as
long as the turn it is meant to interrupt. The agent can only honor an abort
nobody can deliver. Watching input in the host is the smallest place that can
see the byte while the turn blocks, and it fixes the retry wait and streaming
alike (a stalled stream is aborted by the progress callback rather than by a
line arriving).

*Alternatives considered:* running the turn off the key loop with a coroutine —
a large architectural change to the TUI for the same effect; polling only
between slices of the wait — leaves a stalled stream uninterruptible; having the
UI set the flag from its own key handler — cannot happen while the handler's
caller is the turn. Queuing non-interrupt bytes is what makes the watch
harmless: a keystroke typed during a turn reaches the input line instead of
being swallowed.

### 12. An abort keeps its text, a failure discards it

Text already streamed when a turn is aborted is stored and journaled as the
answer; text from a *failed* attempt is discarded.

*Why:* they are different situations. The user chose to stop, so what arrived
is worth keeping (and the existing Ctrl+C comment promises exactly that); a
failure is either retried — and the model may answer differently, so keeping
the old text would make the transcript disagree with history — or terminal.

### 13. TUI: dim rows plus a status-line indicator, no countdown

Retry and continuation notices follow the existing `retry` / `aborted` /
`context_compressed` dim-row convention, and the pending retry also
appears in the status line. The wait shown is the fixed value from the
event, not a live countdown.

*Why:* the TUI deliberately has no background timer ("repaints driven by
events and keypresses are sufficient"), so a countdown would need one
just to animate.

## Risks / Trade-offs

- **Watching stdin in the host could swallow typed input** → every byte that is
  not `0x03` is queued and returned by `read_char`/`read_char_nb` in order, and
  the tests assert it. A closed stdin stops the watch, so piped input (the test
  suites) neither spins nor reports interrupts.
- **The interrupt reaches the agent at its next check, not mid-syscall** → a
  tool that is running when Ctrl+C arrives finishes first; the abort then lands
  at the next agent check. Interrupting a running `run` command would mean
  killing its child process tree, which is a separate change.
- **A stale interrupt could abort the next turn** → the host flag is cleared
  when a turn starts, mirroring the per-turn reset the UI already performs for
  `agent.abort_requested`.

- **Retrying 400/413 without compaction can repeat forever on a genuinely
  oversized payload** → bounded by the cutoff (about two minutes with
  defaults) and the reason states the loop stopped; a user can set
  `retry.max_failures_at_max_delay = 1` or a `max_attempts` cap. This is
  pi-retry's documented trade-off, kept deliberately.
- **The default budget is longer than today's three attempts** → a dead
  network now spends up to ~2 minutes before the error banner. Mitigated
  by the retry row and status-line indicator showing exactly what is
  being waited for, and by the interruptible wait.
- **Discarding a failed attempt's streamed text throws away visible
  output** → the retry regenerates the answer. The alternative (keep the
  text visible but out of history) makes the transcript disagree with
  what the model actually saw, which is worse for trust.
- **A keyword classifier will miss new provider phrasings** → the
  catch-all defaults to retryable, so a missed pattern degrades to
  "retried", not "silently ended"; adding a phrase is a one-line change
  to a pure, tested module.
- **Continuations are uncapped** → bounded by the turn's existing
  50-iteration cap, which they now consume, so a model stuck in `length`
  cannot loop indefinitely.
- **Merging segments hides the boundary from the model on later turns** →
  acceptable: the merged text is exactly what the model produced; only
  the framing message is dropped.
- **Longer waits make the "thinking" placeholder ambiguous** → the status
  line shows the retry indicator for the duration of the wait, and the
  dim row above it explains why.

## Migration Plan

1. Add `src/tether/retry.lua` and wire it into the Makefile
   (`LUA_MODS`, the `luac -p` list, and `tools/embed.lua` arguments) so
   the built binary embeds it.
2. Land the provider stop-reason and provider-error-failure changes
   first; they are additive and keep today's behavior for everything
   else.
3. Switch `api.stream` to the single-attempt contract, then add the loop
   in `agent.main_loop`. Between these two steps the tree does not
   retry, so they should land together.
4. Update the TUI notices last.
5. Tests: the T15 client-retry tests currently assert internal retries
   (`requests == 2` for a 429-then-success script) and must be rewritten
   to the new contract — one request, a retryable failure returned — with
   the retry behavior asserted instead at the policy level and in an
   agent-level test whose stream function fails then succeeds.
6. Rollback: revert the change. Nothing outside the process changed
   format-wise; an older binary ignores the `retry` config table and
   still honors `retries`, and no session or journal shape changed
   (hidden continuations are never journaled), so existing sessions
   resume unchanged either way.
