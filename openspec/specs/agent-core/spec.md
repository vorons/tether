
# agent-core

## Purpose

The agent turn loop: accept user text, drive the LLM, dispatch tool
calls through a confirmation policy, journal to the session, and
manage context growth. The externally visible contract between the UI
and the model is this module.


## Requirements

### Requirement: Agent turn installs the system prompt
The agent SHALL place a system-prompt message at the head of history before the first turn. The prompt SHALL be the composed prompt from context-injection (built-in tool description or `config.system_prompt` base, then AGENTS.md sections, then the skills index). When composition yields nothing beyond the base, the built-in default prompt SHALL be used.

#### Scenario: First turn with no custom prompt
- **WHEN** `agent.turn` runs and `cfg.system_prompt` is nil or empty, and no AGENTS.md or skills are discovered
- **THEN** history[1] is the built-in system prompt with tool listing

#### Scenario: Custom inline prompt
- **WHEN** `cfg.system_prompt` is a multi-line string and no AGENTS.md or skills are discovered
- **THEN** history[1] content equals that string

#### Scenario: Composed prompt in history
- **WHEN** a session starts with a workspace `AGENTS.md` and two discovered skills
- **THEN** `history[1]` is a system message containing the tool description, the `AGENTS.md` content, and the two-skill index

### Requirement: User message is journaled
The agent SHALL append the user text to history and SHALL write a
`message` event (role user) to the session journal before the LLM call.

#### Scenario: Turn with user text
- **WHEN** `agent.turn(cfg, key, "hi", ...)` runs
- **THEN** the session journal contains a `{type:"message", role:"user", content:"hi"}` event

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

### Requirement: Tool-call assembly across SSE chunks
The agent SHALL accumulate `tool_call_start` / `tool_call_delta`
events by call id, preserving order of first appearance. Tool-call
arguments SHALL be kept as raw (JSON-escaped) fragments; unescaping
SHALL happen exactly once, over the full assembled string, before
parsing.

#### Scenario: Arguments split by a chunk boundary mid-escape
- **WHEN** one SSE chunk ends with a backslash and the next chunk
  starts with `n`
- **THEN** the parsed argument is a newline character, not the two
  literal characters

#### Scenario: Truncated tool_call arguments
- **WHEN** an unterminated JSON string is the final assembled argument
- **THEN** `parse_args` returns an empty table and the call is not
  lost or hung

### Requirement: Tool-call assistant message precedes results
The agent SHALL insert the assistant message carrying `tool_calls`
into history and journal it before any `tool_result` for those calls
is appended, matching the OpenAI conversation contract.

#### Scenario: Resume round-trips the sequence
- **WHEN** a session with tool calls is resumed
- **THEN** the reconstructed message sequence contains the
  assistant-with-tool_calls message before the corresponding tool
  results

### Requirement: Assistant text alongside tool calls is retained

When a model response carries both assistant text and tool calls, the
assistant message added to history and to the session journal SHALL
keep the text alongside the `tool_calls` array, so the reasoning shown
to the user is not silently dropped.

#### Scenario: Text plus tool call
- **WHEN** a stream emits `text_delta` "let me check" and then a tool call
- **THEN** the assistant message in history carries both `content="let me check"` and the `tool_calls` array

### Requirement: Tool execution dispatch

The agent SHALL dispatch tool calls by name to the matching tool
implementation (`read`, `list`, `glob`, `grep`, `write`, `run`,
`patch`). A call named `ask` SHALL be dispatched to the interactive
question flow instead of a tool implementation: it never executes
locally, and the agent parks on it until the answer or cancellation
arrives. An unknown tool name SHALL yield a tool result of
`{error="unknown tool: <name>"}`.

#### Scenario: Unknown tool name
- **WHEN** the model emits a tool call named `execute`
- **THEN** the tool_result content is the string
  `unknown tool: execute`

#### Scenario: Ask is not dispatched as a tool
- **WHEN** the model emits a tool call named `ask`
- **THEN** no file or shell tool implementation is invoked for it

### Requirement: Tool results carry their body to the model

For a successful tool call the agent SHALL append a `tool`-role history
message whose content is the tool's output body — the same text the UI
offers when a result is expanded — and SHALL NOT append an empty string.
For a failed tool call the content SHALL be the error text. The one-line
summary SHALL remain the UI/journal representation and SHALL NOT replace
the body in history. A body SHALL be truncated to a documented maximum
with an explicit truncation marker, so a single large result cannot blow
the context budget.

#### Scenario: run output reaches the model
- **WHEN** a `run` call exits 0 and writes `HELLO-OUTPUT` to stdout
- **THEN** the `tool` history message content contains `HELLO-OUTPUT`

#### Scenario: grep matches reach the model
- **WHEN** a `grep` call returns three matches
- **THEN** the `tool` history message content lists the matching file/line/text rows

#### Scenario: Tool error text reaches the model
- **WHEN** a `write` call is refused outside the workspace
- **THEN** the `tool` history message content is the refusal message, not an empty string

#### Scenario: read body unchanged
- **WHEN** a `read` call returns file content
- **THEN** the `tool` history message content is that file content

### Requirement: Confirmation policy for out-of-workspace writes

A tool call SHALL require user confirmation when, and only when:
`allow_outside_workspace` is false AND the tool is `write`, `patch`,
or `run` AND the target path (write/patch target, run cwd) resolves
outside the workspace. A `run` call with no cwd SHALL be considered
inside the workspace root. For `patch`, the target path SHALL be taken
from the diff file headers (the `b/` path when present) before the
containment check.

#### Scenario: Write inside workspace
- **WHEN** the tool call is `write` with a path resolving under the
  workspace
- **THEN** the tool executes without a confirmation event

#### Scenario: Run without cwd
- **WHEN** the tool call is `run` with only a command and no cwd
- **THEN** no confirmation is requested; the command runs in the
  workspace root

#### Scenario: Patch outside the workspace asks the user
- **WHEN** the tool call is `patch` whose `+++ b/...` header resolves outside the workspace
- **THEN** a `confirmation` event is emitted for that call and the patch is not applied until the user decides

#### Scenario: Patch inside the workspace runs directly
- **WHEN** the tool call is `patch` whose target resolves under the workspace
- **THEN** the patch applies without a confirmation event

### Requirement: Confirmation queue drives idempotent events
The agent SHALL maintain a pending queue of tool calls for the
current step. Calls needing confirmation SHALL emit a `confirmation`
event exactly once per call (marked `confirm_emitted`); subsequent
`drive_pending` invocations SHALL park, not re-emit.

#### Scenario: UI re-polls while waiting
- **WHEN** `agent.confirm` is not yet called and the UI re-enters
  `drive_pending`
- **THEN** no second `confirmation` event is emitted for the same call

### Requirement: Confirmation decisions
`agent.confirm(id, decision)` SHALL support decisions:
- `allow` — execute this call only
- `session` — execute and remember the key `tool:path` for the session
- `always` — execute, remember for the session, and persist the key
  to `~/.tether/auto_approve.lua`
- `deny` — record a tool_result of `denied by user`
- `cancel` — deny this call and every queued call with
  `cancelled by user`, clearing the queue

#### Scenario: Always persists a dated entry
- **WHEN** decision is `always` for `write:/abs/path`
- **THEN** `~/.tether/auto_approve.lua` contains the pattern
  `^write:/abs/path$` with a dated comment, and the in-memory
  auto_approve list is updated

#### Scenario: Cancel drains the queue
- **WHEN** decision is `cancel` and three calls were queued
- **THEN** all three get `cancelled by user` tool results and the
  pending queue is cleared

### Requirement: Auto-approve matching
A queued call SHALL skip confirmation when the key `tool:path` or the
raw path matches any pattern in `cfg.auto_approve` (Lua pattern
match), or when the key is in the session-approved set.

#### Scenario: Pattern from auto_approve.lua
- **WHEN** `auto_approve.lua` persists `^run:/tmp/x$` and a later
  run call has cwd `/tmp/x`
- **THEN** no confirmation is requested

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

### Requirement: Context compression at threshold
Before each LLM call, the agent SHALL estimate history tokens
(length-of-content divided by 4, ceiled). When the estimate exceeds
`summarize_at × max_tokens` (defaults 0.7 × 32768), the agent SHALL
compress: keep the system message and the last 4 messages (walking
back over leading tool messages so a tool result is not orphaned
from its call), replace the rest with a single system message whose
content is the truncated (200 chars each) list of old messages, and
emit `context_compressed`.

#### Scenario: Threshold crossed
- **WHEN** estimated tokens exceed 0.7 × max_tokens
- **THEN** the history is rewritten as described and the UI receives
  a `context_compressed` event

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

### Requirement: Tool result summaries for UI
Each tool result SHALL carry a one-line summary rendered by kind:
read → "N стр.", list → "N записей", glob → "N файлов",
grep → "N совп.", run → "exit <code>, <ms|s>", write → "+N B",
patch → "+N −N". An error result SHALL render "✗ <error>".

#### Scenario: Run summary format
- **WHEN** `run` exits with code 2 in 1500 ms
- **THEN** the summary is `exit 2, 1.5 s`

> design.md §6.5 lists these exact summary strings (Russian labels
> included), so the two documents agree.

### Requirement: Tool-call start carries arguments and a projected change
The `tool_call_start` event the agent emits to the UI SHALL carry the call's
parsed arguments, so a renderer can identify the target it is about to touch
without re-parsing the raw model output.

For a `write` or `patch` call the event SHALL additionally carry a read-only
projection of the change it will make, computed from the call arguments before
the tool runs: the target path, which kind of change it is (new file,
overwrite, or patch), the projected unified diff, and its added/removed line
counts. For every other tool no projection SHALL be emitted.

The projection SHALL be computed without side effects: the target is resolved
with symlinks and SHALL lie inside the workspace, a file larger than the
documented bound SHALL NOT be read, nothing SHALL be written, and no history
or journal entry SHALL be produced. A projection that cannot be computed
(unreadable or oversized target, target outside the workspace, malformed
patch, arguments that do not address a file) SHALL be omitted; the call itself
SHALL proceed unchanged, and the event SHALL still carry the parsed arguments.

#### Scenario: Pending write carries a projected diff
- **WHEN** the model emits a `write` call for an existing file inside the workspace
- **THEN** the `tool_call_start` event carries the parsed arguments plus a projection whose diff describes the content change

#### Scenario: New file projects a creation diff
- **WHEN** a `write` call targets a path that does not exist yet
- **THEN** the projection reports a new file and its diff is entirely additions

#### Scenario: Patch projects the submitted diff
- **WHEN** the model emits a `patch` call whose arguments carry a unified diff
- **THEN** the `tool_call_start` event carries a projection with that diff and its counts

#### Scenario: Oversized target is not read
- **WHEN** a `write` call targets a file larger than the documented bound
- **THEN** the event carries the parsed arguments and no projection, and the file is not read

#### Scenario: Outside-workspace target is not read
- **WHEN** a `write` call targets a path outside the workspace
- **THEN** the event carries the parsed arguments and no projection

#### Scenario: Projection never mutates anything
- **WHEN** a `tool_call_start` event for a `write` or `patch` call is produced
- **THEN** the target file and the agent history are unchanged

### Requirement: Write and patch results carry the applied diff
A successful `write` SHALL describe its change as a unified diff — a creation
diff when the file did not exist, otherwise a diff against the previous
content — and a successful `patch` SHALL carry the applied unified diff.

For these two tools the diff SHALL be the result body, so the text the UI
offers on expansion and the text appended to the model's history stay the same
text, subject to the existing truncation maximum. The one-line summary SHALL
report `+N −M`, and for `write` SHALL say whether the file was created or
overwritten. When the previous content could not be read, the result SHALL
fall back to the existing body (the written path for `write`, the applied-file
list for `patch`) and its summary SHALL NOT claim a diff it does not have.

#### Scenario: Overwrite reports a diff
- **WHEN** a `write` replaces the contents of an existing file
- **THEN** the result body is a unified diff of the old and new content, the summary reports `+N −M` and an overwrite, and the model's history carries that same diff

#### Scenario: Creation reports a diff
- **WHEN** a `write` creates a file that did not exist
- **THEN** the result body is a diff made of additions, the summary reports the file as created with `+N −0`, and the model's history carries that same diff

#### Scenario: Patch reports the applied diff
- **WHEN** a `patch` applies cleanly
- **THEN** the result body is the applied unified diff and the model's history carries that same diff

#### Scenario: Failed call keeps the error body
- **WHEN** a `write` or `patch` call fails
- **THEN** the result is the error text as today, with no diff body

#### Scenario: Unreadable previous content falls back
- **WHEN** a `write` overwrites a file whose previous content could not be read
- **THEN** the result body falls back to the written path and the summary does not report diff counts

#### Scenario: Large change is truncated for the model
- **WHEN** the diff body exceeds the documented truncation maximum
- **THEN** the model's history carries the truncated body with the existing truncation marker

### Requirement: Ask parks the turn until the user answers

A tool call named `ask` SHALL NOT be executed through a tool implementation.
The pending queue SHALL instead treat it as an interaction:

- the agent SHALL emit exactly one `ask` event for the call, carrying the call id
  and the normalised question set, and SHALL park the turn;
- a repeated `agent.continue` or queue drive while the turn is parked SHALL NOT
  re-emit that event;
- tool calls queued after the `ask` call SHALL stay pending until it is resolved;
- `agent.answer_ask(id, answer, cfg, on_event)` SHALL record the answer as that
  call's tool result, mark the call done, and drive the queue exactly as a
  confirmation decision does, so the UI can resume the loop through the existing
  continue path;
- the recorded tool result SHALL be appended to the conversation and journaled
  like any other tool result, so a resumed session keeps the answer.

#### Scenario: The event replaces execution
- **WHEN** the model calls `ask` with one question
- **THEN** an `ask` event carries the call id and that question, and no tool implementation runs

#### Scenario: Emitted once
- **WHEN** the turn is parked on an `ask` call and the UI drives the queue again
- **THEN** no second `ask` event is emitted

#### Scenario: The answer resumes the turn
- **WHEN** the user's answer is passed to `agent.answer_ask`
- **THEN** a tool result carrying the answer payload is appended to history and journaled, the queue advances, and the resumed turn sees it

#### Scenario: Calls after an ask wait their turn
- **WHEN** the model emits `ask` and then `read` in one step
- **THEN** `read` does not run until the question is answered or cancelled

#### Scenario: Answer survives a resume
- **WHEN** a session whose turn answered a question is resumed
- **THEN** the conversation contains the `ask` tool result with the answer payload

### Requirement: Ask is not asked in a non-interactive run

When the run has no interactive user, an `ask` call SHALL NOT park the turn and
SHALL NOT emit an `ask` event: it SHALL produce an error tool result explaining
that the user cannot be asked, and the loop SHALL continue with that result, so
the run neither fails nor hangs through the tool.

#### Scenario: Print mode does not park
- **WHEN** a turn running without an interactive user calls `ask`
- **THEN** the call yields an error tool result and the loop makes its next request without waiting

### Requirement: Cancelling an ask cancels its batch

Cancelling an open question set SHALL resolve every `ask` call still pending in
that step with a cancellation tool result, so a model that asked several
questions does not re-prompt immediately; a pending call that is not `ask` SHALL
be unaffected and SHALL run on the normal path.

#### Scenario: Two queued questions, one cancel
- **WHEN** the user cancels while two `ask` calls are pending
- **THEN** both receive the cancellation result and no second question is raised

#### Scenario: A pending write still runs
- **WHEN** a queued `ask` is cancelled and a `write` inside the workspace is pending behind it
- **THEN** the `write` executes as it would without the `ask`
