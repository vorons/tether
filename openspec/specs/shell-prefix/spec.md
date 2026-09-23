# shell-prefix Specification

## Purpose
Shell command prefix: `!cmd` runs a command and feeds output toward the agent; `!!cmd` runs without sending output to the model.

## Requirements

### Requirement: Bang prefix runs a shell command
An input whose first character (after trim) is `!` SHALL NOT be sent to the agent as a user message. The remainder SHALL run as a shell command in the workspace with the same sandbox semantics as the `run` tool (workspace cwd, `TETHER_WORKSPACE`, timeout). Slash-command resolution SHALL run first: `/…` never takes the bang path. A bare `!` with no command SHALL show a one-shot error banner and send nothing.

- `!<command>` — run the command; show the output as a tool-style transcript row; append the output (or a bounded excerpt) as context for the next user/steering message path per the scenario below; do not create a user message row for the `!` line itself beyond the command row.
- `!!<command>` — run the command; show the output as a tool-style transcript row; do NOT include the output in agent history or any future message.

Output SHALL be truncated to the same tool-result bound as `run` when shown. Exit code SHALL appear in the row summary (`exit N`). A non-zero exit SHALL still show the row and SHALL NOT raise the global error banner by itself.

#### Scenario: Bang feeds context
- **WHEN** the user submits `!git status`
- **THEN** the command runs in the workspace, a row shows `git status` output with the exit code, and the output is available to the next agent turn (e.g. appended to the next submitted user message or injected as a tool-style result) without a user-row for `!git status` itself

#### Scenario: Double-bang is local only
- **WHEN** the user submits `!!make test`
- **THEN** the command runs, output is shown in the transcript, and no agent history entry carries that output

#### Scenario: Slash wins over bang
- **WHEN** the user submits `!` as part of a skill or command path that starts with `/`
- **THEN** slash resolution applies (bang is only recognized when the first non-blank character is `!`)

#### Scenario: Empty bang
- **WHEN** the user submits `!` alone
- **THEN** an error banner indicates a missing command and nothing is run or sent
