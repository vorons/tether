# Spec Delta

## ADDED Requirements

### Requirement: Retry and continuation notices
While a turn is being retried or continued the TUI SHALL keep the user
informed with dim system rows, painted as the events arrive and without
waiting for a keypress.

On a `retry` event the TUI SHALL first remove every transcript row
painted for the attempt that just failed — the assistant-text and
reasoning rows that attempt produced — and then append one dim row
naming the failed attempt number, the wait in seconds, and the failure
reason. Rows produced by an earlier attempt SHALL NOT be kept, and rows
produced by the attempt that follows SHALL NOT be removed.

On a `continuation` event the TUI SHALL append one dim row naming what
was continued, so an answer that was stitched together is visibly
stitched.

While the TUI waits between attempts the status line SHALL show the
pending retry — the attempt number and the wait in seconds — in
addition to the turn's own indicator; the ordinary indicator SHALL
return once the next attempt starts. The wait shown SHALL be the fixed
duration carried by the event, not a live countdown, so no background
timer is required.

These rows SHALL behave as transcript rows for scrolling and the
transcript height, SHALL NOT be sent to the agent, and SHALL NOT be
added to the agent history. In ASCII mode they SHALL use ASCII glyphs
and SHALL NOT introduce a non-ASCII glyph.

#### Scenario: The failed attempt's rows are dropped
- **WHEN** an attempt streams `half an ans` and then fails retryably
- **THEN** that text is gone from the transcript and the retry row is
  the last row before the next attempt's output

#### Scenario: The successful attempt's rows are kept
- **WHEN** the attempt after a retry streams an answer
- **THEN** that answer stays in the transcript

#### Scenario: Retry row content
- **WHEN** the third attempt fails and the next wait is 8 seconds
- **THEN** one dim row names attempt 3, the 8-second wait and the
  failure reason

#### Scenario: Continuation row
- **WHEN** a truncated answer is continued
- **THEN** one dim row names the continuation

#### Scenario: Status line during the wait
- **WHEN** the TUI waits 60 seconds before the next attempt
- **THEN** the status line shows the attempt number and the 60-second
  wait, and returns to the ordinary turn indicator when the next
  attempt starts

#### Scenario: Painted without a keypress
- **WHEN** a retry or continuation event arrives
- **THEN** the row is painted while the turn is still running, without
  requiring a keypress

#### Scenario: Retry rows are not agent input
- **WHEN** the retry row is on screen and the turn continues
- **THEN** nothing from the row reaches the agent or its history

#### Scenario: ASCII mode
- **WHEN** ASCII mode is active and a retry row is painted
- **THEN** the row carries only ASCII glyphs

### Requirement: Ctrl+C during a turn
Pressing Ctrl+C while a turn is running SHALL stop that turn. The byte is
consumed by the host while the turn blocks (see the host capability), so the
TUI does not need to read it mid-turn: the agent stops at its next check,
emits `aborted`, and the TUI appends its interrupted row and clears the turn
indicators. Aborting SHALL work whatever the turn is doing when the key is
pressed — streaming a reply, waiting between attempts, or a continuation
segment.

Keys typed while a turn is running SHALL NOT be lost: they SHALL be returned
to the input line in the order typed once the turn ends, exactly like keys
typed between turns.

With no turn running, Ctrl+C SHALL keep its existing meaning: it clears a
non-empty input line, and a second press within the quit window quits.

#### Scenario: The turn stops
- **WHEN** the user presses Ctrl+C while the agent waits between attempts
- **THEN** the turn ends, the interrupted row is appended, and no further attempt is made

#### Scenario: Typed keys survive a turn
- **WHEN** the user types `abc` while a turn is running
- **THEN** the input line holds `abc` when the turn ends

#### Scenario: Idle meaning is unchanged
- **WHEN** no turn is running and the user presses Ctrl+C with text in the input
- **THEN** the input line is cleared

## MODIFIED Requirements

### Requirement: Error banner and overlay
On an agent or API error the TUI SHALL show a one-line error banner
above the input. Pressing Enter on the banner SHALL open the full
error overlay; Esc or Enter in that overlay SHALL dismiss it and
clear it, after which the input field SHALL accept a new message
immediately without further steps. While the overlay is open,
other input is routed to the overlay (modal); it SHALL NOT block
sending a new message once dismissed.

An `aborted` turn is not an error: it SHALL append the dim
`⏹ прервано (Ctrl+C)` transcript row (ASCII `[x] прервано (Ctrl+C)`)
instead of raising the banner, and SHALL clear the waiting, streaming and
pending-retry indicators so no stale spinner or backoff stays on screen.

#### Scenario: Dismiss and send
- **WHEN** an error occurred, the user opens the overlay, presses
  Esc, types a new message, and presses Enter
- **THEN** the new message is sent to the agent

#### Scenario: Banner persists until next submit
- **WHEN** an error banner is showing and the user submits a new
  message without opening the overlay
- **THEN** the banner clears as part of the submit

#### Scenario: An abort shows no banner
- **WHEN** a turn ends with an `aborted` event
- **THEN** the transcript gains the interrupted row and no error banner is set

#### Scenario: An abort clears the indicators
- **WHEN** a turn is aborted while it waited between attempts
- **THEN** no placeholder, caret, elapsed field or pending-retry field remains
