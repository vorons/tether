
# api-client

## Purpose

OpenAI-compatible chat completion client: SSE streaming over the
in-process HTTP client (vendored libcurl + mbedTLS), retry/backoff
policy, key handling, and model listing.

## Requirements

### Requirement: SSE streaming request
The client SHALL select a provider adapter by `cfg.provider` (any catalog id, default `openai`) and POST the provider-specific streaming request: OpenAI-compatible `{"model":..., "messages":..., "stream":true}` JSON to `<base_url>/chat/completions`; Anthropic `{"model":..., "messages":..., "stream":true, "tools":..., "max_tokens":...}` JSON to `<base_url>/v1/messages`; Gemini `{"contents":..., "tools":...}` JSON to `<base_url>/v1beta/models/<model>:streamGenerateContent` (SSE) with REST `generateContent` fallback. Catalog entries whose wire is `openai`, `anthropic`, or `gemini` reuse that wire module with the entry's `base_url` (alias — no new adapter). The request SHALL be issued by the in-process HTTP client (vendored libcurl + mbedTLS): the body is written to a temp file and handed to the client as a file handle, so it never appears in a process argv and no `curl` subprocess is spawned. An empty line in the stream is an event boundary, not EOF; parsing SHALL continue after it. Unknown `cfg.provider` values SHALL fall back to `openai` with a stderr warning.

#### Scenario: Multi-event stream
- **WHEN** the stream contains two `data:` events separated by an
  empty line
- **THEN** both events are parsed and their deltas forwarded

#### Scenario: Unknown provider falls back
- **WHEN** `cfg.provider` is `"azure"` (unknown)
- **THEN** the OpenAI-compatible adapter is used and a stderr warning names the unknown value

#### Scenario: In-process transport
- **WHEN** the agent calls `api.stream(cfg, key, messages, on_event)`
- **THEN** the request is issued through the in-process HTTP client (no `curl` process) and SSE events reach `on_event` in stream order

#### Scenario: Alias preset streams
- **WHEN** `cfg.provider` is `"deepseek"` with no user override
- **THEN** the OpenAI-compatible request is POSTed to `https://api.deepseek.com/chat/completions`

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

### Requirement: Canonical event types
The client SHALL emit to `on_event` these event types, in stream
order: `text_delta` (content unescaped exactly once at this layer),
`reasoning_delta`, `tool_call_start` (id, name), `tool_call_delta`
(raw arguments fragment), `usage` (used = prompt+completion tokens,
plus both raw fields), and `done` (carrying the stop reason). The
client SHALL NOT emit `retry` or `error`: a failure is returned to the
caller as a classified failure record, and the retry policy decides
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
The client SHALL write the `Authorization` header (or the provider's equivalent auth header) to a private temp file (mode 600) and pass that file handle to the in-process HTTP client; the key SHALL not appear in the process argv or in the environment. The temp file SHALL be created with mode 600 before the key is written, so there is no window in which the key is readable by other users; if the mode cannot be applied the client SHALL fail before issuing the request. The header file and request body file SHALL be removed after the request, on both success and failure. When the resolved credential is an OAuth access token, the same header-file path SHALL carry `Authorization: Bearer <token>` (or the provider-specific equivalent); the token SHALL NOT be logged, journaled, or placed in argv. On a classified auth failure with a stored refresh token, the client (or the layer immediately above it) MAY perform one refresh request using the same transport rules before the caller retries.

#### Scenario: Key not visible in ps
- **WHEN** a request is in flight
- **THEN** `ps` shows no key text — the key travels only through the
  mode-600 temp header file, and no `curl` command is spawned

#### Scenario: Header file is private from creation
- **WHEN** the header file is written and before the request starts
- **THEN** its mode is already 600 and no other user can read it

#### Scenario: Temp files are cleaned up
- **WHEN** the request finishes, succeeds or fails
- **THEN** both the header file and the request body file no longer exist

#### Scenario: Key file permissions
- **WHEN** the client prepares a request with an API key
- **THEN** the header temp file exists with mode 600 before the key is written into it

#### Scenario: OAuth bearer uses header file
- **WHEN** the resolved credential is an OAuth access token
- **THEN** the header file carries the provider's bearer/authorization header with the token and argv remains clean

### Requirement: Single attempt per stream call
A call to the streaming entry point SHALL perform exactly one HTTP
request. It SHALL return `ok` plus, on failure, a failure record
carrying the failure message, its kind per the `retry` capability, the
HTTP status when known, and a server-provided `Retry-After` when
present. It SHALL NOT wait, sleep, or repeat the request on its own,
and SHALL NOT emit `retry` or `error` events. The retry policy is the
single owner of the backoff schedule, so a provider-level retry budget
can never multiply another one.

#### Scenario: One request per call
- **WHEN** the first response is a 429 JSON body
- **THEN** exactly one request was issued and the call returns a
  retryable failure, leaving the decision to retry to the policy

#### Scenario: Failure carries Retry-After
- **WHEN** the failure body carries `"retry_after":5`
- **THEN** the returned failure carries 5 as its retry-after value

#### Scenario: Local failure is reported, not raised
- **WHEN** the auth header temp file cannot be written
- **THEN** the call returns a non-retryable failure naming the problem
  and no request is issued

#### Scenario: The client never emits retry or error
- **WHEN** a call fails for any reason
- **THEN** no `retry` and no `error` event is emitted by the client

### Requirement: Provider error events fail the attempt
An error reported by the provider inside the stream SHALL mark the
attempt failed: an Anthropic `error` event, and an OpenAI-compatible or
Gemini `{"error":…}` payload, SHALL each make the call return a failure
carrying the provider's message, derived from that message and the
payload's status when present. Parsing SHALL stop at that point, the
remainder of the stream SHALL only be drained, and the attempt SHALL
never be reported as a successful stream.

#### Scenario: OpenAI error payload
- **WHEN** a chunk carries `{"error":{"message":"rate limit exceeded"}}`
- **THEN** the call returns a failure with that message and a
  retryable kind

#### Scenario: Anthropic error event
- **WHEN** the stream carries an `error` event with a message
- **THEN** the call fails with that message instead of being reported
  as successful

#### Scenario: Gemini error payload
- **WHEN** a response carries `{"error":{"message":"quota exceeded"}}`
- **THEN** the call returns a failure with that message

#### Scenario: Mid-stream error after deltas
- **WHEN** text deltas arrive and an error event follows them
- **THEN** the deltas have been forwarded and the call still fails

### Requirement: Stop reason is surfaced
Every `done` event SHALL carry the reason the model stopped, as one of
`stop`, `length`, `tool_calls` or `other`. The mapping SHALL be:
OpenAI-compatible `finish_reason` `stop` → `stop`, `length` → `length`,
`tool_calls` / `function_call` → `tool_calls`; Anthropic `stop_reason`
`end_turn` / `stop_sequence` → `stop`, `max_tokens` → `length`,
`tool_use` → `tool_calls`, `refusal` → `other`; Gemini `finishReason`
`STOP` → `stop`, `MAX_TOKENS` → `length`, any other reason → `other`.

The reason reported with a `done` SHALL be the last reason the provider
reported for that request, so a terminator that carries no reason of
its own — the `[DONE]` sentinel, the clean end of a stream — repeats
the earlier reason instead of clearing it. When the provider reported
no reason at all, the reason SHALL be `other`. Every `done` SHALL carry
one of the four values.

#### Scenario: OpenAI length
- **WHEN** a chunk carries `"finish_reason":"length"`
- **THEN** the `done` for it reports `length`

#### Scenario: The sentinel repeats the reason
- **WHEN** a chunk reports `length` and a later `[DONE]` sentinel closes
  the stream
- **THEN** both `done` events report `length`

#### Scenario: Anthropic max_tokens
- **WHEN** the final `message_delta` carries the stop reason `max_tokens`
- **THEN** the `done` emitted at `message_stop` reports `length`

#### Scenario: Gemini MAX_TOKENS
- **WHEN** a response carries `finishReason` `MAX_TOKENS`
- **THEN** the `done` for that request reports `length`

#### Scenario: Unmapped reason
- **WHEN** the provider reports a reason outside the mapping
- **THEN** `done` reports `other`

#### Scenario: No reason reported
- **WHEN** a stream ends without any provider-reported reason
- **THEN** `done` reports `other`

### Requirement: Non-SSE error body is surfaced
When the response body is non-empty and does not start with `data:`,
the client SHALL report the attempt as failed instead of returning
success silently: the failure SHALL carry the HTTP status found in the
body when present and a snippet of the body truncated to 200
characters with whitespace collapsed, formatted as
`http <status>: <snippet>`. A provider with a REST fallback MAY first
consume the body into events. The client SHALL NOT emit an `error`
event for it — the retry policy decides whether the failure is retried
and when an error is surfaced.

#### Scenario: 401 JSON body
- **WHEN** the server returns `{"error":{...,"status":401}}`
- **THEN** the call returns a non-retryable failure whose message
  starts `http 401:`

#### Scenario: Unknown status
- **WHEN** the body carries no status field
- **THEN** the failure message starts `http ?:`

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
The client SHALL expose, per provider, a static fallback model list and a live listing that uses the provider's auth mechanism and extracts model ids. OpenAI-compatible live listing GETs `<base_url>/models` with the auth header file; Anthropic live listing GETs `<base_url>/v1/models` with `x-api-key` + `anthropic-version` headers; Gemini live listing GETs `<base_url>/v1beta/models?key=...` and extracts `name` fields. Live listing without a key SHALL return the error "no api key". The static OpenAI fallback keeps the existing 12 entries (gpt-4o-mini ... qwen-plus); Anthropic fallback lists current Claude models; Gemini fallback lists current Gemini models. Catalog presets added by this change (all non-`openai`/`anthropic`/`gemini` ids) SHALL have an empty static fallback: `/model` shows the live list, and an empty/unreachable list with no fallback. Tier-B adapters define their own live listing (Bedrock `ListFoundationModels` discovery, Vertex `models.list`, Azure `/openai/models` on the resource URL — the deployments path is not used for listing, Cloudflare per-gateway catalog, Radius `/v1/config` catalog, Codex models endpoint).

#### Scenario: Live list empty
- **WHEN** `/models` returns a body with no `id` fields
- **THEN** the result is nil with reason "empty model list"

#### Scenario: Per-provider fallback
- **WHEN** the active provider is `anthropic` and the live listing fails
- **THEN** the static Claude list is returned, not the OpenAI list

#### Scenario: Preset has no static list
- **WHEN** the active provider is `groq` and the live listing fails
- **THEN** the model list is empty (no fallback entries)

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

### Requirement: Gemini request and response mapping
With `provider = "gemini"`, the client SHALL convert history to `contents` (`role: user/model`, `parts: [{text} | {functionCall} | {functionResponse}]`), convert the static tool schema to `tools: [{functionDeclarations}]`, stream via `:streamGenerateContent` SSE mapping `candidates[].content.parts[].text` to `text_delta` and `functionCall` (`name`, raw `args` fragment) to `tool_call_start`/`tool_call_delta`, map `usageMetadata` (`promptTokenCount`, `candidatesTokenCount`) to `usage`, and fall back to non-streaming `generateContent` when the SSE endpoint is unavailable. The API key SHALL travel as the `?key=` query parameter built from a file-sourced value, never interpolated into a logged argv string.

#### Scenario: Gemini function call
- **WHEN** a stream chunk carries `functionCall: {name, args}`
- **THEN** `tool_call_start` (name) plus a raw `tool_call_delta` are emitted and the agent parses args exactly once

#### Scenario: Gemini usage mapping
- **WHEN** a chunk carries `usageMetadata` with `promptTokenCount` and `candidatesTokenCount`
- **THEN** `usage.used` equals their sum with both raw fields present

### Requirement: Model list caching

`/model` SHALL serve a fresh disk cache (`~/.tether/models_cache.json`, TTL 4h) with zero network. Otherwise the stale cache (or static list) is shown immediately and one background fetch (`tether.fetch_bg`, forked child, 20s cap) refreshes it; the open palette rebuilds when the fetch lands, otherwise the next open picks it up. Without background fetch support the fallback is a single sync attempt capped at 5s. `checked_at` persists on every attempt so a dead endpoint blocks at most once per TTL, not per open. The timeout argument of the live listing defaults to 30s for other callers.

#### Scenario: Fresh cache is instant
- **WHEN** the cache for the active provider is fresh
- **THEN** no HTTP request is issued and the cached list is shown

#### Scenario: Stale cache shows instantly, refresh lands in background
- **WHEN** the cache is stale and a key is present
- **THEN** the stale list appears with no blocking request and exactly one background fetch runs

#### Scenario: Dead endpoint blocks once
- **WHEN** the live attempt fails and no cache exists
- **THEN** the static list is shown and the next open within TTL issues no request

### Requirement: Per-preset extra headers

The client SHALL append catalog `extra_headers` and provider-required dynamic headers to every request of a preset, after the auth header and before any user override. Required cases (from pi sources): `opencode`/`opencode-go` SHALL send `x-opencode-session: <session id>` (request fails without it); `github-copilot` SHALL send `X-Initiator` (`user`|`agent` by last message role) and `Openai-Intent: conversation-edits`, plus the static editor-identity headers Copilot requires (`User-Agent: GitHubCopilotChat/…`, `Editor-Version`, `Editor-Plugin-Version`, `Copilot-Integration-Id`) — these are provider protocol requirements, not client attribution, and SHALL NOT count against the attribution ban; `Copilot-Vision-Request: true` is sent only when image input exists (first cut: tether history is text-only, the header is omitted); `cloudflare-ai-gateway` SHALL send `cf-aig-authorization: Bearer <key>` and SHALL NOT send `Authorization` or `x-api-key`. No attribution headers SHALL be sent (`HTTP-Referer`, `X-Title`, billing/invoke-origin). No client-chosen `User-Agent` override SHALL be sent beyond the transport default and provider-required identity headers. The session id source is `cfg._session_id`; when unset, `x-opencode-session` SHALL be omitted (not sent empty).

#### Scenario: OpenCode session routing
- **WHEN** `provider = "opencode"` and `cfg._session_id` is set
- **THEN** the request carries `x-opencode-session` with that value

#### Scenario: Cloudflare gateway auth shape
- **WHEN** `provider = "cloudflare-ai-gateway"`
- **THEN** the header file carries `cf-aig-authorization` and no `Authorization` line

#### Scenario: No attribution leakage
- **WHEN** any preset request is in flight
- **THEN** no `HTTP-Referer`, `X-Title`, or billing-origin header is present

### Requirement: Tier-B adapters emit canonical events

Each Tier-B adapter (amazon-bedrock, google-vertex, azure-openai full, cloudflare-ai-gateway URL templating, radius, openai-codex) SHALL emit only the existing canonical event set (`text_delta`, `reasoning_delta`, `tool_call_start`, `tool_call_delta` raw, `usage`, `done` with mapped stop reason) and report failures as classified failure records — never provider-specific events. `agent.lua` SHALL NOT branch on these providers. Bedrock SHALL use the non-streaming Converse API (`POST …/converse`): the ConverseStream eventstream is binary and incompatible with the line-based transport, so the adapter parses the single-shot JSON response and emits the whole answer as canonical events. Streaming on Bedrock is explicitly out of scope until the transport grows a binary-eventstream parser.

#### Scenario: Bedrock tool call round-trip
- **WHEN** a Bedrock Converse response carries a `toolUse` block
- **THEN** `tool_call_start` is emitted and the agent parses args exactly once

#### Scenario: Azure resource URL normalization
- **WHEN** the Azure base URL is a resource root (`*.ai.azure.com`, `*.cognitiveservices.azure.com`, `*.openai.azure.com`)
- **THEN** requests target the normalized OpenAI API path for that resource
