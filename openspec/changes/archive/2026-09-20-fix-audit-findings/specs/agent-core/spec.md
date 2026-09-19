# Spec Delta: agent-core

## ADDED Requirements

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

### Requirement: Assistant text alongside tool calls is retained

When a model response carries both assistant text and tool calls, the
assistant message added to history and to the session journal SHALL
keep the text alongside the `tool_calls` array, so the reasoning shown
to the user is not silently dropped.

#### Scenario: Text plus tool call
- **WHEN** a stream emits `text_delta` "let me check" and then a tool call
- **THEN** the assistant message in history carries both `content="let me check"` and the `tool_calls` array

## MODIFIED Requirements

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
