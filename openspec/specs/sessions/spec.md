
# sessions

## Purpose

Durable session state: JSONL journal under `~/.tether/sessions`,
workspace-scoped resume, input history, and the event schema.


## Requirements

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

### Requirement: Portable session listing

Listing session files for resume SHALL rely only on POSIX-standard
facilities available on every supported platform (Linux and macOS), and
SHALL NOT depend on GNU-only `find` extensions. On a platform without
those extensions the picker data and `latest(workspace)` SHALL still
return the matching sessions.

#### Scenario: GNU find extensions unavailable
- **WHEN** the host `find` does not support `-printf` (e.g. BSD/macOS)
- **THEN** `session_files` and `latest` still return sessions for the workspace, ordered by mtime descending

#### Scenario: Resume works on the same platform
- **WHEN** the user passes `-r` on a platform without GNU `find -printf`
- **THEN** the latest matching session is found and its messages restored

### Requirement: Session picker data
`session_files(workspace)` SHALL return, per matching session, `{id, mtime, ts, first_line}` where `first_line` is the first user `message` content (the picker preview) and `mtime` is the recency rank (1 = newest). The listing SHALL enumerate the `*.jsonl` files under the session directory and order them by modification time descending, with ties broken by id for determinism, and SHALL be limited to the 100 most recent files. The listing SHALL be obtained through the in-process `tether.readdir` and `tether.stat` primitives — no `find`, `ls -1t` or `head` shell pipeline.

#### Scenario: Picker preview
- **WHEN** a session's first user message is "fix the login bug"
- **THEN** the picker row shows that text as the preview

#### Scenario: Listing is ordered by mtime
- **WHEN** the session directory holds more sessions than the picker cap
- **THEN** only the 100 most recent are returned, ordered newest first with `mtime` as the 1-based rank

#### Scenario: No shell pipeline
- **WHEN** the listing runs
- **THEN** it spawns no `find`/`ls`/`head` process and reads the directory through `tether.readdir` and `tether.stat`

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

> gap: the abort flag is not persisted — `session_end` carries only
> `{workspace, model}`. design.md §10 documents that as the current
> behavior.
