# Proposal: archive existing tether behavior as OpenSpec capabilities

## Why

tether has shipped M1–M9 (287/287 tests green) with no durable spec
inventory. `openspec/specs/` is empty. This change captures the
**currently observed behavior** of the shipped binary as seven
capabilities, using live code and tests as the source of truth.
`docs/design.md` is treated as intent: where code and design disagree,
the spec documents the code and records the drift inline. Nothing is
rewritten in the codebase by this change.

## What Changes

- **New Capabilities** (each becomes `specs/<capability>/spec.md`
  under this change, promoted to `openspec/specs/` at archive):
  - `agent-core` — agent turn loop, tool-call queue, confirmation
    policy, abort, history compression/summarization, token estimate.
  - `api-client` — OpenAI-compatible SSE streaming, retry policy,
    auth header handling, model listing.
  - `tools` — read/list/glob/grep/write/patch/run behavior, workspace
    path policy, atomic write, strict patch application.
  - `sessions` — JSONL journal, resume by workspace, input history,
    session picker data.
  - `tui` — terminal I/O behavior, layout regions, markdown-lite
    rendering, mouse SGR, palette, themes, ASCII mode, status line,
    overlays.
  - `config` — `~/.tether/config.lua` schema, defaults, deep-merge
    load, API key env resolution, system prompt resolution,
    auto-approve persistence.
  - `host` — C host: termios raw mode, signal handling, `tether.*`
    Lua API surface, pipe read semantics, embedded-binary build flow.
- **Modified Capabilities**: none (first spec inventory).

## Impact

- Planning artifacts only: one change directory under
  `openspec/changes/archive-existing-behavior/`. No source changes.
- Archive of this change creates the main spec inventory under
  `openspec/specs/` with a `## Purpose` per capability.
- Drift notes inside the specs are informational; they do not change
  code and are not a task list (fixing drift is a separate, future
  change).
