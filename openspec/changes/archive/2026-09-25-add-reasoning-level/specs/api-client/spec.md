# Spec Delta

## ADDED Requirements

### Requirement: Reasoning level reaches the request

The client SHALL apply the configured reasoning level — `cfg.reasoning`,
values `off` (default) / `low` / `medium` / `high` — to the request body of
the wires that support it, and SHALL leave every other request field
(history, tools, stream flags) unchanged:

- OpenAI-compatible chat-completions (wire `openai`): for a level other than
  `off` the body SHALL carry `"reasoning_effort":"low"`, `"medium"` or
  `"high"` accordingly; for `off` the parameter SHALL be omitted entirely.
- Anthropic (wire `anthropic`): for a level other than `off` the body SHALL
  carry `"thinking":{"type":"enabled","budget_tokens":N}` with N = 4096 for
  `low`, 16384 for `medium` and 65536 for `high`, and a `max_tokens` of at
  least N plus 4096 answer tokens; for `off` the `thinking` field SHALL be
  omitted.
- Any other wire SHALL send the request it sends today: the level is
  accepted and displayed but not mapped.

A `cfg.reasoning` value outside the four levels SHALL behave as `off`.

#### Scenario: Effort on the OpenAI body

- **WHEN** `cfg.reasoning` is `high` and the provider is `agnes`
- **THEN** the request body carries `"reasoning_effort":"high"` and nothing else about the request changes

#### Scenario: Off sends no parameter

- **WHEN** `cfg.reasoning` is `off`
- **THEN** neither `reasoning_effort` nor `thinking` appears in the request body

#### Scenario: Anthropic budget fits the completion window

- **WHEN** `cfg.reasoning` is `medium` and the provider is `anthropic`
- **THEN** the body carries `"thinking":{"type":"enabled","budget_tokens":16384}` and a `max_tokens` of at least 20480

#### Scenario: Unsupported wire keeps its request

- **WHEN** `cfg.reasoning` is `high` and the wire is `gemini`
- **THEN** the request body is exactly what it would be with `off`

#### Scenario: Unknown level behaves as off

- **WHEN** `cfg.reasoning` is `"turbo"`
- **THEN** the request carries no reasoning parameter

## MODIFIED Requirements

### Requirement: Canonical event types

The client SHALL emit to `on_event` these event types, in stream
order: `text_delta` (content unescaped exactly once at this layer),
`reasoning_delta`, `tool_call_start` (id, name), `tool_call_delta`
(raw arguments fragment), `usage` (used = prompt+completion tokens,
plus both raw fields), and `done` (carrying the stop reason). The
client SHALL NOT emit `retry` or `error`: a failure is returned to
the caller as a classified failure record, and the retry policy decides
whether it is retried and when an error is surfaced.

A reasoning chunk in the stream SHALL be emitted as `reasoning_delta`
and SHALL NOT be emitted as `text_delta`: an OpenAI-compatible
`delta.reasoning_content` (or its `delta.reasoning` alias) and an
Anthropic `content_block_delta` carrying `thinking_delta` SHALL each
map to `reasoning_delta`, unescaped exactly once like content. Other
reasoning-shaped fields (`signature_delta`, request echo fields) SHALL
emit nothing.

#### Scenario: Usage event

- **WHEN** a chunk carries `prompt_tokens` and `completion_tokens`
- **THEN** `usage.used` equals their sum

#### Scenario: Done carries a reason

- **WHEN** the model finishes an answer
- **THEN** the `done` event carries one of `stop`, `length`,
  `tool_calls`, `other`

#### Scenario: A failure is not an event

- **WHEN** an attempt fails
- **THEN** no `error` event is emitted and the failure is returned to
  the caller instead

#### Scenario: OpenAI reasoning chunk

- **WHEN** a chunk carries `"delta":{"reasoning_content":"let's plan"}`
- **THEN** one `reasoning_delta` carries that text and no `text_delta` is emitted for it

#### Scenario: Anthropic thinking chunk

- **WHEN** a `content_block_delta` carries `"thinking_delta"` and a later one carries `"signature_delta"`
- **THEN** the thinking chunk becomes one `reasoning_delta` and the signature chunk emits nothing

#### Scenario: Reasoning never becomes answer text

- **WHEN** a stream emits reasoning deltas and then `text_delta` chunks for `Hello`
- **THEN** `text_delta` events carry only `Hello`; the reasoning text arrived solely as `reasoning_delta`

### Requirement: Anthropic request and SSE mapping

With `provider = "anthropic"`, the client SHALL send `x-api-key: <key>` (via the private header file, never argv), `anthropic-version: 2023-06-01`, and `content-type: application/json`; convert history so `tool`-role messages become `tool_result` content blocks and assistant `tool_calls` become `tool_use` blocks; convert the static tool schema to Anthropic `tools` + `tool_choice`; and map the SSE stream: `content_block_delta` with `text_delta` to `text_delta`, `thinking_delta` to `reasoning_delta` (`signature_delta` ignored), `input_json_delta` (raw fragment) to `tool_call_delta` addressed by `index`, `message_delta`/`message_stop` to `usage`/`done`. `max_tokens` defaults to a provider minimum when unset; when the reasoning level is enabled, the request SHALL carry the `thinking` parameter and a `max_tokens` as defined by the reasoning-level requirement.

#### Scenario: Anthropic tool use round-trip

- **WHEN** a stream carries `content_block_start` (tool_use, id, name) then `input_json_delta` fragments by index
- **THEN** one `tool_call_start` plus raw `tool_call_delta` fragments are emitted and the agent parses args exactly once

#### Scenario: Anthropic auth headers

- **WHEN** an Anthropic request is in flight
- **THEN** `ps` shows no key text and the header file carries `x-api-key` (not `Authorization: Bearer`)

#### Scenario: Anthropic thinking round-trip

- **WHEN** the request enables thinking and the stream carries `content_block_delta` events with `thinking_delta`
- **THEN** each chunk is emitted as `reasoning_delta` before the `text_delta` chunks that follow it
