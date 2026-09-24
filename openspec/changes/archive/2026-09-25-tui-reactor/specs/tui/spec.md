# Spec Delta

## MODIFIED Requirements

### Requirement: Live turn feedback

The TUI SHALL show turn progress while the agent works, without waiting for the turn to finish. On submit it SHALL paint the waiting state immediately: the input box's top rule status SHALL show a leading space, the spinner frame, and `Working...`, advancing on repaints while the turn runs. The transcript SHALL carry no waiting placeholder — only real entries (user, assistant, thinking, tool, system rows) plus the caret `▌` (ASCII `|`) at the end of the newest line while deltas keep arriving; the caret SHALL NOT be drawn while the user has scrolled up or while the palette, confirmation menu, ask block, or login secret mode owns the keyboard. Thinking rows SHALL render as `thinking · Ns` with the live elapsed seconds of the reasoning so far. Assistant rows SHALL use the `•` marker (ASCII `-`). Text and tool progress SHALL become visible during the turn: the TUI SHALL repaint while the turn is running, throttled by a bounded number of skipped deltas, and SHALL repaint immediately on state transitions (tool call start, tool result, error, abort, confirmation). Repaints are driven by reactor ticks: the spinner advances on tick cadence even with no stream events, and a tick that dispatched input SHALL repaint at once instead of waiting out the delta throttle. Input is live by construction while busy — keys, wheel and resize dispatch on the tick they arrive, so Enter / Alt+Enter / Escape are handled mid-turn (steering capability) without waiting for the next model or tool event; dispatch SHALL NOT block for input and SHALL NOT run while a confirmation menu, ask block, or login secret mode owns the keyboard. An escape sequence split across ticks SHALL be buffered and retried whole and SHALL NEVER reach the input line as text. The input-box indicator, caret and elapsed fields SHALL be cleared when the turn ends — after a reply, on error, on abort, and when a confirmation menu is raised (the turn is then waiting on the user) — and SHALL apply equally to a turn resumed after a confirmation decision. The elapsed counter SHALL reset at the start of each turn. In ASCII mode the spinner SHALL use ASCII frames (the caret is `|`, the assistant marker is `-`) and no non-ASCII glyph SHALL be introduced by this feedback.

#### Scenario: Working indicator in the top rule

- **WHEN** the user submits a message and no token has arrived yet
- **THEN** the input box's top rule status shows a leading space, the spinner frame plus `Working...` and the transcript carries no placeholder row

#### Scenario: First delta keeps the indicator until the turn ends

- **WHEN** the first text or reasoning delta arrives
- **THEN** the transcript row appears, the caret is drawn at the end of the newest line, and the top rule keeps showing the spinner with `Working...` until the turn settles

#### Scenario: Thinking shows elapsed time

- **WHEN** reasoning streams for several seconds
- **THEN** the thinking row reads `thinking · Ns` with the elapsed seconds

#### Scenario: Text appears before the turn returns

- **WHEN** the model streams an answer
- **THEN** frames painted while the turn is still running already contain the streamed text prefixed with `•`

#### Scenario: Transitions repaint immediately

- **WHEN** a tool call starts or a tool result arrives
- **THEN** a frame for that event is painted without waiting for the delta throttle

#### Scenario: Cleared when the turn ends

- **WHEN** a turn ends after a reply, an error, or an abort
- **THEN** no Working indicator, caret or elapsed field remains, and the input box's top rule is a plain dim rule again

#### Scenario: Confirmation clears the busy state

- **WHEN** a tool call requires confirmation and the menu is raised
- **THEN** the Working indicator, caret and elapsed fields are cleared while the turn waits for the user

#### Scenario: Caret is not drawn while scrolled up

- **WHEN** the user has scrolled up while deltas are still arriving
- **THEN** no caret is drawn on the newest visible row

#### Scenario: Caret is not drawn while a modal surface owns the keyboard

- **WHEN** the palette, confirmation menu, ask block, or login secret mode is open while deltas arrive
- **THEN** no caret is drawn on the newest visible row

#### Scenario: ASCII mode

- **WHEN** ASCII mode is active during a turn
- **THEN** the spinner uses ASCII frames, the caret is `|`, the assistant marker is `-`, and no non-ASCII glyph is emitted by the feedback

#### Scenario: No repaint is required while nothing happens

- **WHEN** no turn is running and no key arrives
- **THEN** the TUI is not required to repaint and the last painted frame stays on screen

#### Scenario: Busy pump handles Enter mid-stream

- **WHEN** the user presses Enter with text while deltas are streaming
- **THEN** the steering queue accepts the message without waiting for the turn to end and without starting a second turn

#### Scenario: Scroll applies on a silent tick

- **WHEN** the user scrolls while the turn waits with no stream events in flight
- **THEN** the viewport moves and repaints within one tick quantum, without waiting for the next model or tool event

#### Scenario: Fragmented sequence never leaks

- **WHEN** a mouse sequence arrives split across two ticks mid-turn
- **THEN** the input line stays unchanged and the completed sequence dispatches as one mouse event

#### Scenario: Confirmation blocks the pump

- **WHEN** a confirmation menu is open and the user presses Enter
- **THEN** only the confirmation handler acts; no steering message is queued
