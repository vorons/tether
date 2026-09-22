# Spec Delta

## Purpose

Retry policy for provider failures and truncated answers: classify a
failure as retryable or not, compute the exponential-backoff wait and
the cutoff, and decide when an answer continues instead of ending.

## ADDED Requirements

### Requirement: Error classification
The policy SHALL classify a failed attempt from its error text and
optional HTTP status into exactly one kind, and derive from that kind
whether the failure is retryable. Matching SHALL be case-insensitive
over the failure text, and the kind SHALL be one of:
`quota`, `permanent`, `connection`, `credit`, `request`, `server`,
`empty`, `unknown`.

Precedence SHALL be `quota`, then `permanent`, then the retryable
kinds; a quota or permanent failure is never retryable. When no
pattern matches, the kind SHALL be `unknown`, which SHALL be
retryable — an unrecognised provider error is retried rather than
silently ending the turn.

Each kind SHALL carry a human-readable reason that names the failure
without repeating the whole provider message, so a notice can explain
why a retry happened or why it did not.

#### Scenario: Unknown error is retryable
- **WHEN** the failure text is something no pattern recognises
- **THEN** the kind is `unknown` and the failure is retryable

#### Scenario: Status alone classifies
- **WHEN** a failure carries HTTP status 429 and no recognisable text
- **THEN** the kind is `server` and the failure is retryable

#### Scenario: Classification is case-insensitive
- **WHEN** the failure text contains `OVERLOADED` in upper case
- **THEN** it is classified `server` and is retryable

### Requirement: Non-retryable permanent failures
The policy SHALL NOT retry failures that cannot succeed on a second
attempt: an invalid, missing, or revoked API key, an authentication
rejection, a model that does not exist, an unknown model, and an
unsupported model. Such a failure SHALL be classified `permanent` and
SHALL end the retry loop at once, with the reason surfaced.

#### Scenario: Invalid API key
- **WHEN** the failure text is `invalid api key`
- **THEN** the kind is `permanent`, the failure is not retryable, and no
  further attempt is made

#### Scenario: Unknown model
- **WHEN** the failure text is `The model 'gpt-9' does not exist`
- **THEN** the kind is `permanent` and the failure is not retryable

#### Scenario: Authentication status
- **WHEN** a failure carries HTTP status 401 or 403 and matches no quota
  pattern
- **THEN** the kind is `permanent`

### Requirement: Non-retryable quota, session-limit and budget failures
The policy SHALL NOT retry an exhausted usage or session limit, a
plan or billing quota, a hard model allotment, a spending budget, or a
suspended account: retrying cannot succeed until the reset window
passes or the user acts. Such a failure SHALL be classified `quota` and
SHALL end the retry loop at once, with a reason that explains the loop
was stopped rather than failed.

The detected set SHALL include reset-window usage limits (`you've hit
your limit`, usage-limit reached/exceeded, 5-hour limit reached),
`insufficient_quota`, exceeded current quota, exhausted model capacity,
per-model quota limits with a resume time, free-tier and coding-plan
allotments, a premium request allowance, an exceeded spending budget
(`out of budget`, budget exceeded), and a suspended account.

A plain pay-as-you-go balance failure SHALL NOT be classified `quota`:
`insufficient balance`, `insufficient credits`, `not enough credits`,
`out of credits` and a `Payment Required` / HTTP 402 failure stay
retryable, because a top-up mid-loop can resume them.

#### Scenario: Usage limit stops the loop
- **WHEN** the failure text is `You've hit your limit · resets in 3 hours`
- **THEN** the kind is `quota`, the failure is not retryable, and the
  reason says the loop stopped because the limit is exhausted

#### Scenario: Plan quota is not retried
- **WHEN** the failure text is `You exceeded your current quota, please
  check your plan and billing details`
- **THEN** the kind is `quota` and no further attempt is made

#### Scenario: Balance stays retryable
- **WHEN** the failure text is `Insufficient Balance` with HTTP status 402
- **THEN** the kind is `credit` and the failure is retryable

#### Scenario: Suspended account is not retried
- **WHEN** the failure text is `Your account is suspended`
- **THEN** the kind is `quota` and the failure is not retryable

### Requirement: Retryable failure kinds
Besides the catch-all `unknown` kind, the policy SHALL classify these
failures as retryable:

- `connection`: connection and network failures — connection reset,
  refused, timed out or not resolving, a socket hang up, DNS lookup
  failure, TLS handshake failure, an upstream connect error, a request
  that ended without sending chunks, and stream exhaustion (`max
  outbound streams`).
- `credit`: credit and payment failures — the phrases listed in the
  quota requirement's final paragraph, and HTTP 402.
- `request`: HTTP 400 and HTTP 413, and the texts `bad request` and
  `payload too large`. These SHALL be retried without reducing the
  context, so a transient overflow is not answered with a compression.
- `server`: HTTP 429 and HTTP 5xx, and the texts `rate limit`, `too
  many requests`, `overloaded`, `internal server error`, `bad gateway`
  and `service unavailable`.
- `empty`: a response body that carried nothing.

#### Scenario: Connection error is retryable
- **WHEN** the failure text contains `ECONNRESET`
- **THEN** the kind is `connection` and the failure is retryable

#### Scenario: Stream exhaustion is retryable
- **WHEN** the failure text is `Max outbound streams is 100, 100 open`
- **THEN** the kind is `connection` and the failure is retryable

#### Scenario: Bad request is retryable
- **WHEN** a failure carries HTTP status 413
- **THEN** the kind is `request` and the failure is retryable

#### Scenario: Empty body is retryable
- **WHEN** an attempt returns no body at all
- **THEN** the kind is `empty` and the failure is retryable

### Requirement: Exponential backoff schedule
The wait before the next attempt SHALL follow the configured
exponential schedule: `base_delay_ms` (default 2000),
`max_delay_ms` (default 60000), `multiplier` (default 2) and
`max_failures_at_max_delay` (default 3). The wait for the n-th failed
attempt SHALL be `min(base_delay_ms × multiplier^(n-1), max_delay_ms)`,
capped at `max_delay_ms`.

A missing, non-numeric, or non-positive value SHALL fall back to its
default; a `multiplier` below 1 SHALL be treated as 1. A wait SHALL
never be negative.

#### Scenario: Default sequence
- **WHEN** attempts keep failing with the default configuration
- **THEN** the waits before attempts 2 through 8 are 2, 4, 8, 16, 32,
  60, 60 seconds

#### Scenario: Multiplier applies
- **WHEN** `base_delay_ms` is 1000 and `multiplier` is 3 and the first
  wait is due
- **THEN** the wait is 1 second, and after a second failure 3 seconds

#### Scenario: Cap applies
- **WHEN** the computed wait exceeds `max_delay_ms`
- **THEN** the wait is exactly `max_delay_ms`

#### Scenario: Invalid configuration falls back
- **WHEN** `base_delay_ms` is `0`, `multiplier` is `0.5`, and
  `max_failures_at_max_delay` is `"three"`
- **THEN** the effective values are the defaults 2000, 1 and 3

### Requirement: Retry-After overrides the wait
When a failure carries a server-provided `Retry-After` (or
`retry_after`) value, the wait before the next attempt SHALL be that
value instead of the computed schedule wait.

#### Scenario: Retry-After 5
- **WHEN** a 429 failure carries `"retry_after":5` and the computed wait
  is 2 seconds
- **THEN** the policy waits 5 seconds before the next attempt

### Requirement: Retry cutoff
The retry loop SHALL stop when the attempt succeeds, when the user
aborts, when the failure is not retryable, or when the schedule
reaches its cutoff: after `max_failures_at_max_delay` failures whose
computed schedule wait is `max_delay_ms`, the loop SHALL stop instead
of waiting again. A server-provided `Retry-After` SHALL change only the
duration of a wait, never whether that wait counts toward the cutoff.

When the loop stops without success it SHALL surface exactly one error
naming the number of attempts made and the last reason; it SHALL NOT
surface an error for an attempt that is about to be retried.

When an attempt cap is configured, the loop SHALL also stop once that
many attempts have been made.

#### Scenario: Defaults exhaust
- **WHEN** every attempt fails with a retryable `server` failure and the
  configuration is the default
- **THEN** eight attempts are made, the third failure whose schedule
  wait would be `max_delay_ms` ends the loop, and one error names 8
  attempts

#### Scenario: No error for a retried attempt
- **WHEN** the first attempt fails retryably and the second succeeds
- **THEN** no error is surfaced for the first attempt

#### Scenario: Attempt cap
- **WHEN** the configuration caps attempts at 3
- **THEN** the loop stops after the third attempt even if the cutoff
  has not been reached

#### Scenario: Abort stops the loop
- **WHEN** the user aborts while a wait is in progress
- **THEN** the loop stops and no further attempt is made

### Requirement: Continuation on output-token truncation
When an attempt ends because the model reached its output-token limit
(stop reason `length`) and produced no tool calls, the policy SHALL
continue the answer instead of ending the turn. The continuation SHALL
be a user-role message instructing the model to resume exactly where it
stopped without repeating what it already wrote, so no provider
receives a trailing assistant message. Text produced by the
continuation SHALL extend the same assistant answer rather than start a
new one.

Continuations SHALL NOT be capped: they repeat until an attempt ends
with a normal stop reason, the turn's iteration budget is exhausted, or
the retry cutoff stops the turn. A continuation SHALL NOT trigger
context compression, and SHALL NOT appear as a user row in the
transcript.

#### Scenario: Truncated answer is finished
- **WHEN** the first attempt stops with `length` after `part one` and the
  continuation stops normally after `part two`
- **THEN** one assistant answer containing `part one` and `part two` is
  recorded and a continuation notice is surfaced

#### Scenario: Continuation is provider-valid
- **WHEN** a continuation is sent
- **THEN** the messages handed to the provider end with a user-role
  message

#### Scenario: Tool calls take precedence
- **WHEN** a truncated attempt also produced tool calls
- **THEN** no continuation is sent and the tool loop proceeds

#### Scenario: Continuations repeat
- **WHEN** successive attempts each stop with `length`
- **THEN** a continuation is sent after each one until the stop reason
  is no longer `length` or the turn's iteration budget is exhausted

#### Scenario: No compression for a continuation
- **WHEN** a continuation is issued
- **THEN** the conversation is not compressed for it

### Requirement: Empty-stop nudge
An attempt that ends with a normal stop reason and produced neither
text nor tool calls SHALL be retried exactly once, with a user-role
message telling the model its previous turn was empty and to answer
now. Reasoning output alone SHALL count as no text. The nudge SHALL NOT
wait on the backoff schedule, and at most one nudge SHALL be issued per
turn.

When the nudged attempt is also empty, the policy SHALL give up and
report an `empty` failure instead of nudging again.

#### Scenario: Empty stop is nudged once
- **WHEN** an attempt stops normally with no text and no tool calls
- **THEN** one nudge is sent immediately and the answer it produces is
  kept

#### Scenario: Thinking-only stop counts as empty
- **WHEN** an attempt emits only reasoning output and then stops
- **THEN** a nudge is sent

#### Scenario: Give up after a second empty stop
- **WHEN** the nudged attempt is also empty
- **THEN** no third attempt is made and an `empty` failure is reported

### Requirement: Retry state is scoped to one turn
Attempt counters, the cutoff counters, the continuation state, and the
empty-stop nudge flag SHALL be reset at the start of each user turn, so
every turn gets a full budget and a fresh nudge.

#### Scenario: New turn gets a full budget
- **WHEN** a turn exhausts its retry budget and the user sends a new
  message
- **THEN** the next turn starts at attempt 1
