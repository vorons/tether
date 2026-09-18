# Spec Delta

## Purpose

OpenAI-compatible chat completion client: SSE streaming over a curl
pipe, retry/backoff policy, key handling, and model listing.

## ADDED Requirements

### Requirement: SSE streaming request
The client SHALL POST `{"model":..., "messages":..., "stream":true}`
JSON to `<base_url>/chat/completions` and parse the response as SSE
lines (`data: ` prefix). The request body SHALL be passed to curl via
`--data-binary @<file>` (stdin-file, not argv) to avoid shell
quoting. An empty line in the stream is an event boundary, not EOF;
parsing SHALL continue after it.

#### Scenario: Multi-event stream
- **WHEN** the stream contains two `data:` events separated by an
  empty line
- **THEN** both events are parsed and their deltas forwarded

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
The client SHALL expose a static fallback model list (12 entries:
gpt-4o-mini ... qwen-plus) and a live listing that GETs
`<base_url>/models` with the auth header file and extracts `id`
fields. Live listing without a key SHALL return the error
"no api key".

#### Scenario: Live list empty
- **WHEN** `/models` returns a body with no `id` fields
- **THEN** the result is nil with reason "empty model list"

> drift: design.md §6.8 says `/model` falls back to the static list;
> the static list is a fixed 12-entry set and provider-specific, so
> `cfg.model` is the intended direct control (README notes this).
