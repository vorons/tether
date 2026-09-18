
# agent-core

## Purpose

The agent turn loop: accept user text, drive the LLM, dispatch tool
calls through a confirmation policy, journal to the session, and
manage context growth. The externally visible contract between the UI
and the model is this module.


## Requirements

### Requirement: Agent turn installs the system prompt
The agent SHALL place a system-prompt message at the head of history
before the first turn. The prompt SHALL come from
`config.get_system_prompt(cfg)` when non-nil, otherwise the built-in
default prompt describing the available tools.

#### Scenario: First turn with no custom prompt
- **WHEN** `agent.turn` runs and `cfg.system_prompt` is nil or empty
- **THEN** history[1] is the built-in system prompt with tool listing

#### Scenario: Custom inline prompt
- **WHEN** `cfg.system_prompt` is a multi-line string
- **THEN** history[1] content equals that string

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

### Requirement: Tool execution dispatch
The agent SHALL dispatch tool calls by name to the matching tool
implementation (`read`, `list`, `glob`, `grep`, `write`, `run`,
`patch`). An unknown tool name SHALL yield a tool result of
`{error="unknown tool: <name>"}`.

#### Scenario: Unknown tool name
- **WHEN** the model emits a tool call named `execute`
- **THEN** the tool_result content is the string
  `unknown tool: execute`

### Requirement: Confirmation policy for out-of-workspace writes
A tool call SHALL require user confirmation when, and only when:
`allow_outside_workspace` is false AND the tool is `write`, `patch`,
or `run` AND the target path (write/patch target, run cwd) resolves
outside the workspace. A `run` call with no cwd SHALL be considered
inside the workspace root.

#### Scenario: Write inside workspace
- **WHEN** the tool call is `write` with a path resolving under the
  workspace
- **THEN** the tool executes without a confirmation event

#### Scenario: Run without cwd
- **WHEN** the tool call is `run` with only a command and no cwd
- **THEN** no confirmation is requested; the command runs in the
  workspace root

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

> drift: design.md §6.5 does not fix exact summary strings; the code
> is the source of record for them (Russian labels included).
