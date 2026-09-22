# Spec Delta

## ADDED Requirements

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

## MODIFIED Requirements

### Requirement: Canonical event types
The client SHALL emit to `on_event` these event types, in stream
order: `text_delta` (content unescaped exactly once at this layer),
`reasoning_delta`, `tool_call_start` (id, name), `tool_call_delta`
(raw arguments fragment), `usage` (used = prompt+completion tokens,
plus both raw fields), and `done` (carrying the stop reason). The
client SHALL NOT emit `retry` or `error`: a failure is returned to the
caller as a classified failure record, and the retry policy decides
whether it is retried and when an error is surfaced.

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

## REMOVED Requirements

### Requirement: Retry policy
**Reason**: The client no longer owns a retry loop. Repeating a request
with a per-provider budget multiplied the new turn-level schedule, and
the hardcoded 0.5/1.0/2.0 s waits and 3-attempt cap could not express
the longer backoff a throttled provider needs. The `retry` capability
now classifies failures and owns the schedule, and the agent turn runs
the loop.

**Migration**: Nothing to configure differently: a client call now does
one attempt and returns a failure record with its kind, status and
retry-after. Set `retry.base_delay_ms`, `retry.max_delay_ms`,
`retry.multiplier` and `retry.max_failures_at_max_delay` in
`~/.tether/config.lua` for the schedule; a legacy top-level `retries`
still caps the number of attempts.

### Requirement: Retry-After honored
**Reason**: Honoring `Retry-After` is part of the retry policy, which no
longer lives in the client. The client only reports the value.

**Migration**: No configuration change. The failure record carries
`retry_after`, and the policy uses it as the wait before the next
attempt instead of the computed schedule value.

### Requirement: Exhaustion surfaces an error
**Reason**: An attempt that is about to be retried must not look like a
terminal error, and the client no longer knows whether the policy will
retry. Surfacing the error moved to the retry loop.

**Migration**: No configuration change. The loop emits a single error
naming the attempt count and reason when it stops without success;
`--print` mode keeps exiting non-zero on a turn that produced no text.
