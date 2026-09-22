# Spec Delta

## ADDED Requirements

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

## MODIFIED Requirements

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
