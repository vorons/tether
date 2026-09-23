# steering Specification

## Purpose
Busy-time input: how the TUI accepts and classifies submits while a turn is running (steer vs follow-up), how Escape restores the queue, and how non-blocking keys are pumped during the turn.

## Requirements

### Requirement: Busy-time key pump
While a turn is busy (`S.busy` and no confirmation menu or ask block owns the keyboard), the TUI SHALL drain pending input using non-blocking reads on each paint/event tick (stream deltas, tool events, retry waits). The pump SHALL NOT block waiting for a key. Confirmation menus and ask blocks SHALL keep exclusive keyboard ownership: when either is open, the busy pump SHALL NOT steal keys.

#### Scenario: Key arrives mid-stream
- **WHEN** the user presses Enter while `text_delta` events are arriving
- **THEN** the key is handled during the busy pump without waiting for the turn to end

#### Scenario: Confirmation owns the keyboard
- **WHEN** a confirmation menu is open and the user presses Enter
- **THEN** the confirmation handler receives the key and the busy pump does not also queue a message

### Requirement: Enter while busy queues a steering message
Enter on a non-empty input while busy SHALL: append a user row to the transcript immediately, push the text onto the steering queue (FIFO), clear the input, and NOT start a second concurrent `agent.turn`. When the current assistant segment finishes (after its tool-call step completes or the answer ends with no tools), the agent SHALL inject the next steering message as a user message (journaled like any user message) and continue the loop with that message guiding the next LLM call. Steering injection SHALL NOT occur between retry attempts of an in-flight segment.

#### Scenario: Steer during streaming
- **WHEN** the user types `use tabs not spaces` and presses Enter while the model is streaming
- **THEN** the transcript shows the user row at once, no second turn starts, and after the current segment the message is injected before the next LLM call

#### Scenario: Steer after tool step
- **WHEN** the model has emitted tool calls, tools are running, and the user presses Enter with text
- **THEN** the steering message is injected after that tool step's results are recorded, before the next LLM call

#### Scenario: Steer is journaled
- **WHEN** a steering message is injected
- **THEN** the session journal contains a user `message` event for it

### Requirement: Alt+Enter while busy queues a follow-up
Alt+Enter on a non-empty input while busy SHALL queue a follow-up message (separate FIFO from steering): transcript user row immediately, input cleared, no second turn. Follow-ups SHALL run only after the agent fully settles (turn returns with no parked confirmation/ask and no pending steering), as a fresh turn on the same history, in queue order. When idle, Alt+Enter SHALL keep its existing behavior (insert a newline) so multi-line editing is unchanged.

#### Scenario: Follow-up waits for settle
- **WHEN** the user Alt+Enters `then run the tests` while busy
- **THEN** after the current turn completes and steering queue drains, a new turn starts with that text

#### Scenario: Idle Alt+Enter still inserts newline
- **WHEN** the agent is idle and the user presses Alt+Enter
- **THEN** a newline is inserted into the input (existing multi-line behavior)

### Requirement: Escape while busy restores the queue
Escape while busy and at least one queued message (steering or follow-up) exists SHALL: abort the current run (existing abort seam), clear both queues, and place all queued texts back into the editor joined by newlines in submission order (steering first, then follow-ups). No queued message is dropped. If queues are empty, Escape while busy SHALL behave as today (clear input / no-op path unchanged for empty input).

#### Scenario: Escape restores order
- **WHEN** the user queues two steering messages and one follow-up, then presses Escape while busy
- **THEN** the current run aborts and the input holds the three texts in order, one per line

#### Scenario: Escape with empty queue
- **WHEN** the user presses Escape while busy with no queued messages
- **THEN** behavior matches the pre-change empty-queue path (input cleared or no-op per existing rules)

### Requirement: Steering queue cap
Each queue (steering, follow-up) SHALL hold at most 8 messages. A submit that would exceed the cap SHALL show a one-shot error banner (e.g. `queue full (8)`) and SHALL NOT enqueue or drop silently; the input text is preserved for the user to edit or clear.

#### Scenario: Cap exceeded
- **WHEN** 8 steering messages are already queued and the user presses Enter with more text
- **THEN** an error banner appears, the input still holds the text, and the queue length stays 8
