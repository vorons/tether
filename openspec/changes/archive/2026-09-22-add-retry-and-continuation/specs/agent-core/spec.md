# Spec Delta

## ADDED Requirements

### Requirement: Turn-level retry applies the retry policy
Each provider attempt SHALL be one call to the streaming entry point,
and the agent turn SHALL be the only owner of the retry loop: when an
attempt fails with a retryable kind, the agent SHALL wait as the
`retry` capability requires and attempt the same request again with the
same conversation — without re-adding the user message, without adding
a second system prompt, and without compressing the conversation
between attempts. When the failure is not retryable, or the policy's
cutoff is reached, the turn SHALL end with a single `error` event
carrying the failure's reason.

A failed attempt SHALL contribute nothing to the conversation: text it
streamed SHALL NOT be added to the history and SHALL NOT be journaled.
Only a successful attempt's output becomes part of the conversation.

Before each wait the agent SHALL emit a `retry` event carrying the
failed attempt number, the wait in seconds, and a reason describing the
failure. It SHALL NOT emit an `error` event for an attempt it is about
to retry.

#### Scenario: Retry then success
- **WHEN** the first attempt fails with a retryable failure and the
  second succeeds with text
- **THEN** a `retry` event is emitted, the answer is recorded, the
  history holds exactly one user message for the turn, and no `error`
  event is emitted

#### Scenario: Failed attempt leaves no trace
- **WHEN** an attempt streams text and then fails retryably
- **THEN** that text is absent from the history and from the journal

#### Scenario: Permanent failure ends the turn
- **WHEN** an attempt fails with an invalid API key
- **THEN** no wait and no further attempt happen and one `error` event
  is emitted

#### Scenario: No compression between attempts
- **WHEN** an attempt fails retryably and the history is over the
  summarization threshold
- **THEN** the retry re-sends the same conversation, uncompressed

#### Scenario: Abort during an attempt
- **WHEN** the user aborts while an attempt is streaming
- **THEN** the existing abort behavior applies and no retry follows

### Requirement: Streamed output is tagged with its attempt
Every `text_delta` and `reasoning_delta` the agent forwards SHALL carry
the 1-based index of the attempt that produced it, and the `retry`
event SHALL name the attempt that just failed, so a renderer can
discard exactly the rows of the failed attempt and keep those of the
attempt that succeeds.

#### Scenario: Deltas name their attempt
- **WHEN** the agent is on its second attempt and streams text
- **THEN** the forwarded deltas carry attempt 2

#### Scenario: Retry names the failed attempt
- **WHEN** attempt 1 fails and the agent waits before retrying
- **THEN** the `retry` event names attempt 1

### Requirement: Abort interrupts the retry wait
The wait between attempts SHALL be interruptible: the agent SHALL check
for an abort at short intervals while waiting (at most 250 ms between
checks), and the host SHALL wake the wait as soon as input arrives (see
the host capability), so a Ctrl+C during a wait is honored at once rather
than after the remaining backoff. An abort SHALL stop the loop, emit one
`aborted` event, make no further attempt — including when the abort
arrives during the last allowed wait — and keep the answer text
accumulated so far, journaled as a single assistant message.

#### Scenario: Abort during a long wait
- **WHEN** the user presses Ctrl+C while the agent waits 60 seconds
- **THEN** the wait ends immediately, `aborted` is emitted, and no
  further attempt is made

#### Scenario: Abort already set
- **WHEN** the abort is already set when an attempt fails
- **THEN** the agent neither waits nor retries

#### Scenario: A waiting turn carries no retry error
- **WHEN** a turn is aborted during a wait
- **THEN** the loop stops with `aborted` and no `error` event

#### Scenario: Text from a continued answer survives
- **WHEN** a turn is aborted during a continuation segment
- **THEN** the text produced so far is kept as the answer and journaled

### Requirement: Continuation keeps one assistant answer
When an attempt is continued because it was truncated or because it was
empty, the text the continuation produces SHALL extend the same
assistant answer instead of starting a new one: the history SHALL gain
no second assistant entry for that answer, the hidden continuation
message SHALL be removed from the history once its segment completes,
and the continuation SHALL NOT be journaled as a user message. Before
sending a continuation the agent SHALL emit a `continuation` event
naming whether it follows a truncation (`length`) or an empty stop
(`empty`).

The completed, merged answer SHALL be journaled once, as a single
assistant message. When the turn ends before the answer completes, the
text accumulated so far SHALL still be journaled so a resume keeps it.

#### Scenario: Merged answer
- **WHEN** an attempt is truncated after `part one` and the continuation
  ends normally after `part two`
- **THEN** the history holds one assistant message carrying both parts
  and no user message for the continuation

#### Scenario: Hidden message does not linger
- **WHEN** a continuation segment completes
- **THEN** the history no longer contains the hidden continuation message

#### Scenario: Journaled once
- **WHEN** an answer spans one continuation and then ends normally
- **THEN** the journal holds exactly one assistant message for it

#### Scenario: Continuation event
- **WHEN** the agent continues a truncated answer
- **THEN** a `continuation` event naming `length` is emitted

#### Scenario: Partial answer survives an abort
- **WHEN** the user aborts during a continuation segment
- **THEN** the text accumulated before the abort is journaled

### Requirement: Empty answer gives up with an explanation
When the retry policy reports an `empty` failure because an answer
stayed empty after its single nudge, the turn SHALL end with one `error`
event explaining that no usable output was produced, so the user is not
left with a silent turn. A turn that produced nothing at all SHALL NOT
be reported as a successful turn.

#### Scenario: Give up after the nudge
- **WHEN** an empty stop is nudged and the nudged attempt is also empty
- **THEN** one `error` event is emitted and the turn ends

#### Scenario: Print mode
- **WHEN** `--print` runs a turn whose answer stayed empty
- **THEN** the run exits non-zero through the existing empty-response
  contract

## MODIFIED Requirements

### Requirement: Abort during stream
The agent SHALL honor an abort requested while a turn runs: the current
stream is drained for `usage` events only, then the turn returns and
emits an `aborted` event. The abort SHALL be read from the host
(`tether.abort_requested`), which raises it the moment Ctrl+C arrives —
including while the turn blocks on a stream or on a backoff wait — and
from `abort_requested`, which the UI sets between turns; either source
SHALL end the turn the same way.

An aborted turn SHALL NOT be treated as a failed attempt: the loop SHALL
NOT retry it and SHALL NOT emit an `error` for it. Text the attempt had
already streamed SHALL be kept — stored and journaled as the answer — so a
long reply interrupted near its end is not thrown away.

#### Scenario: Ctrl+C mid-stream
- **WHEN** `abort_requested` is set during streaming
- **THEN** no further text_delta is forwarded and `on_event` gets
  `{type="aborted"}`

#### Scenario: The host supplies the abort
- **WHEN** Ctrl+C arrives while a turn is blocked on the transport
- **THEN** the abort is read from the host, the stream stops, and
  `{type="aborted"}` is emitted

#### Scenario: An abort is not a failure
- **WHEN** a turn is aborted
- **THEN** no `retry` and no `error` event is emitted for it

#### Scenario: Received text is kept
- **WHEN** a turn that already streamed `Hello` is aborted
- **THEN** one assistant message with `Hello` is stored and journaled

### Requirement: Streaming text is forwarded to the UI
The agent SHALL emit each `text_delta` and `reasoning_delta` event from
the API stream to the `on_event` callback as it arrives; the final
assistant text SHALL be accumulated and stored in history when the
stream ends without tool calls. When the stream ends because the model
hit its output-token limit, the accumulated text SHALL NOT be stored as
a finished answer: it is kept as the answer so far and completed by a
continuation, and only the merged text is stored once the answer ends.

#### Scenario: Plain-text reply
- **WHEN** the model streams "Hello" and stops
- **THEN** `on_event` receives text_delta for each chunk and one
  `{role:"assistant", content:"Hello"}` message is added to history
  and journaled

#### Scenario: Truncated reply is not final
- **WHEN** the model streams "Hello" and stops with reason `length`
- **THEN** no assistant message is stored for that segment alone; the
  merged answer is stored once the continuation ends

### Requirement: Iteration cap
The agent turn loop SHALL run at most 50 LLM iterations; exceeding
the cap SHALL end the turn successfully (no error event). A
continuation of a truncated answer SHALL count as one iteration, so an
answer that never stops cannot continue forever.

#### Scenario: 50 iterations reached
- **WHEN** the model keeps emitting tool calls
- **THEN** after the 50th iteration the loop exits without further
  streaming

#### Scenario: Continuations count
- **WHEN** the model keeps stopping with reason `length`
- **THEN** each continuation consumes one iteration and the cap ends
  the turn without an error event
