
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

### Requirement: Streaming text is forwarded to the UI
The agent SHALL emit each `text_delta` and `reasoning_delta` event from
the API stream to the `on_event` callback as it arrives; the final
assistant text SHALL be accumulated and stored in history when the
stream ends without tool calls.

#### Scenario: Plain-text reply
- **WHEN** the model streams "Hello" and stops
- **THEN** `on_event` receives text_delta for each chunk and one
  `{role:"assistant", content:"Hello"}` message is added to history
  and journaled

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
`patch`). An unknown tool name SHALL yield a tool result of
`{error="unknown tool: <name>"}`.

#### Scenario: Unknown tool name
- **WHEN** the model emits a tool call named `execute`
- **THEN** the tool_result content is the string
  `unknown tool: execute`

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

### Requirement: Abort during stream
The agent SHALL honor `abort_requested` set by Ctrl+C: the current
stream is drained for `usage` events only, then the turn returns and
emits an `aborted` event.

#### Scenario: Ctrl+C mid-stream
- **WHEN** `abort_requested` is set during streaming
- **THEN** no further text_delta is forwarded and `on_event` gets
  `{type="aborted"}`

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
the cap SHALL end the turn successfully (no error event).

#### Scenario: 50 iterations reached
- **WHEN** the model keeps emitting tool calls
- **THEN** after the 50th iteration the loop exits without further
  streaming

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
