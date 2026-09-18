# Spec Delta: api-client

## MODIFIED Requirements

### Requirement: SSE streaming request
The client SHALL select a provider adapter by `cfg.provider` (`openai` | `anthropic` | `gemini`, default `openai`) and POST the provider-specific streaming request: OpenAI-compatible `{"model":..., "messages":..., "stream":true}` JSON to `<base_url>/chat/completions`; Anthropic `{"model":..., "messages":..., "stream":true, "tools":..., "max_tokens":...}` JSON to `<base_url>/v1/messages`; Gemini `{"contents":..., "tools":...}` JSON to `<base_url>/v1beta/models/<model>:streamGenerateContent` (SSE) with REST `generateContent` fallback. The request body SHALL be passed to curl via `--data-binary @<file>` (stdin-file, not argv) to avoid shell quoting. An empty line in the stream is an event boundary, not EOF; parsing SHALL continue after it. Unknown `cfg.provider` values SHALL fall back to `openai` with a stderr warning.

#### Scenario: Multi-event stream
- **WHEN** the stream contains two `data:` events separated by an empty line
- **THEN** both events are parsed and their deltas forwarded

#### Scenario: Unknown provider falls back
- **WHEN** `cfg.provider` is `"azure"` (unknown)
- **THEN** the OpenAI-compatible adapter is used and a stderr warning names the unknown value

### Requirement: Model listing
The client SHALL expose, per provider, a static fallback model list and a live listing that uses the provider's auth mechanism and extracts model ids. OpenAI-compatible live listing GETs `<base_url>/models` with the auth header file; Anthropic live listing GETs `<base_url>/v1/models` with `x-api-key` + `anthropic-version` headers; Gemini live listing GETs `<base_url>/v1beta/models?key=...` and extracts `name` fields. Live listing without a key SHALL return the error "no api key". The static OpenAI fallback keeps the existing 12 entries (gpt-4o-mini ... qwen-plus); Anthropic fallback lists current Claude models; Gemini fallback lists current Gemini models.

#### Scenario: Live list empty
- **WHEN** `/models` returns a body with no `id` fields
- **THEN** the result is nil with reason "empty model list"

#### Scenario: Per-provider fallback
- **WHEN** the active provider is `anthropic` and the live listing fails
- **THEN** the static Claude list is returned, not the OpenAI list

## ADDED Requirements

### Requirement: Provider dispatch preserves canonical events
The client SHALL route `stream(cfg, api_key, messages, on_event)` and `list_models*()` through the active provider adapter while emitting the existing canonical event set in stream order: `text_delta` (content unescaped exactly once at this layer), `reasoning_delta`, `tool_call_start` (id, name), `tool_call_delta` (raw arguments fragment), `usage` (used = prompt+completion tokens, plus both raw fields), `retry`, `error`, `done`. Retry/backoff, `Retry-After`, key-in-argv, and non-SSE-error contracts apply unchanged to every provider.

#### Scenario: Agent loop unchanged
- **WHEN** the provider is `anthropic` or `gemini` and the model returns text plus a tool call
- **THEN** `agent.lua` assembles history, confirmations and resume without provider-specific branches

### Requirement: Anthropic request and SSE mapping
With `provider = "anthropic"`, the client SHALL send `x-api-key: <key>` (via the private header file, never argv), `anthropic-version: 2023-06-01`, and `content-type: application/json`; convert history so `tool`-role messages become `tool_result` content blocks and assistant `tool_calls` become `tool_use` blocks; convert the static tool schema to Anthropic `tools` + `tool_choice`; and map the SSE stream: `content_block_delta` with `text_delta` to `text_delta`, `input_json_delta` (raw fragment) to `tool_call_delta` addressed by `index`, `message_delta`/`message_stop` to `usage`/`done`. `max_tokens` defaults to a provider minimum when unset.

#### Scenario: Anthropic tool use round-trip
- **WHEN** a stream carries `content_block_start` (tool_use, id, name) then `input_json_delta` fragments by index
- **THEN** one `tool_call_start` plus raw `tool_call_delta` fragments are emitted and the agent parses args exactly once

#### Scenario: Anthropic auth headers
- **WHEN** an Anthropic request is in flight
- **THEN** `ps` shows no key text and the header file carries `x-api-key` (not `Authorization: Bearer`)

### Requirement: Gemini request and response mapping
With `provider = "gemini"`, the client SHALL convert history to `contents` (`role: user/model`, `parts: [{text} | {functionCall} | {functionResponse}]`), convert the static tool schema to `tools: [{functionDeclarations}]`, stream via `:streamGenerateContent` SSE mapping `candidates[].content.parts[].text` to `text_delta` and `functionCall` (`name`, raw `args` fragment) to `tool_call_start`/`tool_call_delta`, map `usageMetadata` (`promptTokenCount`, `candidatesTokenCount`) to `usage`, and fall back to non-streaming `generateContent` when the SSE endpoint is unavailable. The API key SHALL travel as the `?key=` query parameter built from a file-sourced value, never interpolated into a logged argv string.

#### Scenario: Gemini function call
- **WHEN** a stream chunk carries `functionCall: {name, args}`
- **THEN** `tool_call_start` (name) plus a raw `tool_call_delta` are emitted and the agent parses args exactly once

#### Scenario: Gemini usage mapping
- **WHEN** a chunk carries `usageMetadata` with `promptTokenCount` and `candidatesTokenCount`
- **THEN** `usage.used` equals their sum with both raw fields present
