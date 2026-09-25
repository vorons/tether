# Proposal

## Why

The canonical event `reasoning_delta`, the thinking row renderer
(`thinking · Ns ▾`) and the `agent-core`/`api-client` specs that wire them
up already exist, but no provider ever emits the event: no request carries a
reasoning parameter and no stream parser reads reasoning chunks — so a user
can never see the model think, and has no way to trade latency for answer
quality. On top of that there is no UI to pick how hard the model thinks and
no at-a-glance indicator of the current choice.

## What Changes

- **Reasoning level setting**: new top-level `cfg.reasoning` with values
  `off` (default) / `low` / `medium` / `high`; an unknown value falls back to
  `off` without failing the session.
- **Requests carry the level** for the two in-scope wires:
  - `openai` wire (chat-completions: openai, agnes, copilot, azure, …):
    `"reasoning_effort":"low|medium|high"` for a non-`off` level, the
    parameter omitted entirely for `off`.
  - `anthropic` wire: `"thinking":{"type":"enabled","budget_tokens":N}`
    (low 4096 / medium 16384 / high 65536) plus a `max_tokens` large enough
    to cover budget + answer; omitted for `off`.
  - Other wires (gemini, bedrock, codex, radius, …) keep today's request: the
    level is accepted but not sent — a separate change wires them up.
- **Streams emit `reasoning_delta`** for the same two wires:
  - `openai`: `delta.reasoning_content` (and the `delta.reasoning` alias
    used by some gateways) → `reasoning_delta`; it is never accumulated into
    the answer text or the agent history.
  - `anthropic`: `content_block_delta` with `thinking_delta` →
    `reasoning_delta` (`signature_delta` ignored).
  This makes the existing thinking row reachable for the first time.
- **`/think` slash command** (slash menu entry): `/think <level>` applies a
  level directly; bare `/think` opens the level picker in the shared palette
  (same mechanism as `/model`). The pick is echoed as a system row
  (`→ мышление: medium`) and persisted to `~/.tether/config.lua`, so a
  restart restores it.
- **Footer shows the level**: the right-aligned cell becomes
  `provider/model · <level>` — always, including `off`.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `openspec/specs/api-client/spec.md`: new requirement — the configured
  reasoning level reaches the request body of the openai and anthropic wires
  (and is omitted for `off` / unsupported wires); canonical-event and
  Anthropic-mapping requirements gain the reasoning→`reasoning_delta` stream
  mappings and a scenario that reasoning chunks never become answer text.
- `openspec/specs/config/spec.md`: defaults gain `reasoning "off"`; the
  machine-written key set grows from `provider`/`model` to also include
  `reasoning` (the `/think` picker persists it under the same byte-preserving
  writer rules).
- `openspec/specs/tui/spec.md`: the palette's built-in list gains `/think`;
  the session-commands requirement gains `/think` semantics (direct apply,
  picker, echo row, error on unknown level); the footer requirement defines
  the `provider/model · <level>` right cell; live turn feedback gains a
  scenario that reasoning deltas render as a thinking row.

## Impact

- **Code**: `src/tether/config.lua` (default + `PERSIST_KEYS` + key-match in
  the config rewriter), `src/tether/api.lua` (pass `cfg` to the adapter's
  request builder), `src/tether/providers/openai.lua` and
  `src/tether/providers/anthropic.lua` (request parameter + stream mapping),
  `src/tether/ui.lua` (`SLASH_COMMANDS`, `execute_command`, palette mode
  `think`, footer cell).
- **Specs**: deltas in `api-client`, `config`, `tui` (see above).
- **Tests**: request-body assertions per wire, stream-parsing tests for
  `reasoning_delta` (and that history stays answer-only), `/think` command +
  palette tests, footer-cell test, config default/persist tests.
- **Not affected**: `agent-core` (already specifies forwarding and attempt
  tags), the transcript module (thinking rows already implemented),
  resume/journal format.
