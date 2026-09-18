# Spec Delta

## Purpose

Durable session state: JSONL journal under `~/.tether/sessions`,
workspace-scoped resume, input history, and the event schema.

## ADDED Requirements

### Requirement: Journal is append-only JSONL
A session SHALL be one file `~/.tether/sessions/<uuid>.jsonl`;
events are appended one JSON object per line and never rewritten.
The first event SHALL be `session_start` carrying
`meta.{workspace, model}` and an ISO timestamp.

#### Scenario: New session file
- **WHEN** a session is created for workspace `/x` model `o3`
- **THEN** the file's first line is a `session_start` event with
  those meta fields

### Requirement: Event types
The journal SHALL record events of type `session_start`, `message`
(user/assistant, with `tool_calls` for assistant tool steps),
`tool_call`, `tool_result`, `summary`, `session_end`. `tool_result`
SHALL carry `{tool_call_id, name, result}` where result is either
`{error}` or `{summary}`.

#### Scenario: Tool result summary only
- **WHEN** a tool call succeeds
- **THEN** the journaled result holds `result.summary` (one-line),
  not the full body

### Requirement: Resume by workspace
`latest(workspace)` SHALL list session files matching
`meta.workspace` (checked on the first and last event), ordered by
mtime descending, and return the newest. `resume(id)` SHALL rebuild
the OpenAI message sequence: `message` events as user/assistant
messages (assistant with `tool_calls` preserved), `tool_result`
events as tool-role messages with the summary as content.

#### Scenario: No matching session
- **WHEN** `-r` is given and no session file matches the workspace
- **THEN** the app reports this and starts a new session

#### Scenario: Tool-call chain intact
- **WHEN** resuming a session that contains tool calls
- **THEN** the rebuilt sequence places each assistant-with-tool_calls
  message before its tool results (API-legal ordering)

### Requirement: Session picker data
`session_files(workspace)` SHALL return, per matching session,
`{id, mtime, ts, first_line}` where first_line is the first
user `message` content (the picker preview). The picker SHALL be
limited to the 100 most recent files.

#### Scenario: Picker preview
- **WHEN** a session's first user message is "fix the login bug"
- **THEN** the picker row shows that text as the preview

### Requirement: Resume round-trip exits the API contract
A resumed conversation SHALL be accepted by the OpenAI-compatible
API on the next turn: every assistant `tool_calls` message SHALL be
followed by the corresponding tool-role messages before the next
user/assistant message.

#### Scenario: First turn after resume
- **WHEN** the user sends a new message after `-r`
- **THEN** the API call does not fail with a missing-tool-response
  400

### Requirement: Input history
Typed input SHALL be appended to `~/.tether/history.jsonl` as
`{ts, workspace, text}`. The TUI loads the most recent entries for
Up/Down history navigation.

#### Scenario: History is per-machine global
- **WHEN** the user submits prompts across workspaces
- **THEN** all of them land in the same history file, tagged with
  their workspace

### Requirement: Session end
On TUI exit (or print-mode completion) the app SHALL append a
`session_end` event with the same meta as `session_start` and abort
flag when the turn was interrupted.

#### Scenario: Ctrl+C exit
- **WHEN** the user aborts the turn and quits
- **THEN** the session_end event marks the abort in meta

> drift: design.md §10 mentions `aborted` in meta but the shipped
> code writes `session_end` with only `{workspace, model}`; the
> abort flag is not yet persisted.
