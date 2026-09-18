
# api-client

## Purpose

OpenAI-compatible chat completion client: SSE streaming over a curl
pipe, retry/backoff policy, key handling, and model listing.


## Requirements

### Requirement: SSE streaming request
The client SHALL select a provider adapter by `cfg.provider` (`openai` | `anthropic` | `gemini`, default `openai`) and POST the provider-specific streaming request: OpenAI-compatible `{"model":..., "messages":..., "stream":true}` JSON to `<base_url>/chat/completions`; Anthropic `{"model":..., "messages":..., "stream":true, "tools":..., "max_tokens":...}` JSON to `<base_url>/v1/messages`; Gemini `{"contents":..., "tools":...}` JSON to `<base_url>/v1beta/models/<model>:streamGenerateContent` (SSE) with REST `generateContent` fallback. The request body SHALL be passed to curl via `--data-binary @<file>` (stdin-file, not argv) to avoid shell quoting. An empty line in the stream is an event boundary, not EOF; parsing SHALL continue after it. Unknown `cfg.provider` values SHALL fall back to `openai` with a stderr warning.

#### Scenario: Multi-event stream
- **WHEN** the stream contains two `data:` events separated by an
  empty line
- **THEN** both events are parsed and their deltas forwarded

#### Scenario: Unknown provider falls back
- **WHEN** `cfg.provider` is `"azure"` (unknown)
- **THEN** the OpenAI-compatible adapter is used and a stderr warning names the unknown value

### Requirement: Canonical event types
The client SHALL emit to `on_event` these event types, in stream
order: `text_delta` (content unescaped exactly once at this layer),
`reasoning_delta`, `tool_call_start` (id, name), `tool_call_delta`
(raw arguments fragment), `usage` (used = prompt+completion tokens,
plus both raw fields), `retry`, `error`, `done`.

#### Scenario: Usage event
- **WHEN** a chunk carries `prompt_tokens` and `completion_tokens`
- **THEN** `usage.used` equals their sum

### Requirement: Tool-call argument deltas stay raw
The client SHALL emit `tool_call_delta.arguments` as the raw,
still-JSON-escaped fragment from the SSE payload. Unescaping SHALL
happen exactly once in the agent, over the full assembled string.

#### Scenario: Continuation chunk without id
- **WHEN** a tool-call chunk carries only `{"index":0,
  "function":{"arguments":"..."}}`
- **THEN** a `tool_call_delta` with `index` is emitted, matched to
  the call by index

### Requirement: API key never in argv
The client SHALL write the `Authorization` header to a private temp
file (mode 600) and pass it to curl via `-H @<file>`; the key SHALL
not appear in the process argv. The header file and request body file
SHALL be removed after the request, on both success and failure.

#### Scenario: Key not visible in ps
- **WHEN** a request is in flight
- **THEN** `ps` shows the curl command with `-H @/tmp/...`, not the
  key text

### Requirement: Retry policy
On a retryable response, the client SHALL retry up to
`cfg.retries` attempts (default 3) with backoff 0.5s / 1.0s / 2.0s.
A response is retryable when: the body is empty, the body's HTTP
status field is 429 or >= 500, or the body text matches rate-limit
phrases ("rate limit", "too many requests", "overloaded",
"internal server error", "bad gateway", "service unavailable").
A successful SSE stream (body starting with `data:`) is never
retryable.

#### Scenario: 429 then success
- **WHEN** the first attempt returns a 429 JSON body and the second
  returns a valid SSE stream
- **THEN** a `retry` event is emitted and the stream is consumed

#### Scenario: Non-retryable 4xx
- **WHEN** the body reports status 401
- **THEN** no retry happens

### Requirement: Retry-After honored
When the error body carries `Retry-After` (or `retry_after`), the
client SHALL use that value instead of the backoff schedule for the
next attempt.

#### Scenario: Retry-After 5
- **WHEN** a 429 body includes `"retry_after":5`
- **THEN** the client sleeps 5 s before the next attempt

### Requirement: Exhaustion surfaces an error
When all retry attempts are used, the client SHALL emit a single
`error` event: `API failed after <N> attempts: <reason>` and return
false to the agent.

#### Scenario: Three failed attempts
- **WHEN** attempts 1 through 3 all yield retryable bodies
- **THEN** the error message names the attempt count and reason

### Requirement: Non-SSE error body is surfaced
When the response body is non-empty and does not start with `data:`,
the client SHALL emit an `error` event with `http <status>: <200-char
body snippet>` instead of returning success silently.

#### Scenario: 401 JSON body
- **WHEN** curl returns `{"error":{...,"status":401}}`
- **THEN** `on_event` receives `error` with message starting
  `http 401:`

### Requirement: Message encoding
`encode_messages` SHALL serialize the history to the OpenAI messages
array: assistant messages with `tool_calls` get
`content: null` plus the tool_calls array (id, type "function",
function.name, function.arguments as a JSON string); tool-role
messages carry `tool_call_id` and content; all string content SHALL
be JSON-escaped.

#### Scenario: Assistant tool-call round-trip
- **WHEN** history contains an assistant message with tool_calls
- **THEN** the encoded JSON has `"role":"assistant","content":null`
  and the tool_calls array with escaped arguments

### Requirement: Model listing
The client SHALL expose, per provider, a static fallback model list and a live listing that uses the provider's auth mechanism and extracts model ids. OpenAI-compatible live listing GETs `<base_url>/models` with the auth header file; Anthropic live listing GETs `<base_url>/v1/models` with `x-api-key` + `anthropic-version` headers; Gemini live listing GETs `<base_url>/v1beta/models?key=...` and extracts `name` fields. Live listing without a key SHALL return the error "no api key". The static OpenAI fallback keeps the existing 12 entries (gpt-4o-mini ... qwen-plus); Anthropic fallback lists current Claude models; Gemini fallback lists current Gemini models.

#### Scenario: Live list empty
- **WHEN** `/models` returns a body with no `id` fields
- **THEN** the result is nil with reason "empty model list"

#### Scenario: Per-provider fallback
- **WHEN** the active provider is `anthropic` and the live listing fails
- **THEN** the static Claude list is returned, not the OpenAI list

> `/model` falls back to the static list of the *active* provider (the
> OpenAI fallback is the fixed 12-entry set); `cfg.model` remains the
> direct control for pinning a model (README notes this). design.md
> §6.8 now documents the same behavior.

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
