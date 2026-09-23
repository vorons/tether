# Spec Delta

## MODIFIED Requirements

### Requirement: Live turn feedback
The TUI SHALL show turn progress while the agent works, without waiting for the turn to finish. On submit it SHALL paint the waiting state immediately: the newest transcript row SHALL carry a `✻ tether думает…` placeholder with a spinner frame, and the input box's top rule SHALL carry the same spinner with the elapsed seconds of the turn. The placeholder SHALL disappear with the first `text_delta` or `reasoning_delta` and SHALL give way to a caret `▌` (ASCII `|`) at the end of the newest line while deltas keep arriving; the caret SHALL NOT be drawn while the user has scrolled up or while the palette, confirmation menu, ask block, or login secret mode owns the keyboard. Text and tool progress SHALL become visible during the turn: the TUI SHALL repaint while the turn is running, throttled by a bounded number of skipped deltas, and SHALL repaint immediately on state transitions (tool call start, tool result, error, abort, confirmation). No background timer SHALL be required: repaints driven by events and keypresses are sufficient, and the spinner advances only when the TUI repaints. While busy, the TUI SHALL additionally pump non-blocking key reads on each paint/event tick so Enter / Alt+Enter / Escape are handled mid-turn (steering capability); the pump SHALL NOT block for input and SHALL NOT run while a confirmation menu, ask block, or login secret mode owns the keyboard. The waiting placeholder, caret and elapsed field SHALL be cleared when the turn ends — after a reply, on error, on abort, and when a confirmation menu is raised (the turn is then waiting on the user) — and SHALL apply equally to a turn resumed after a confirmation decision. The elapsed counter SHALL reset at the start of each turn. In ASCII mode the spinner SHALL use ASCII frames (the caret is `|`) and no non-ASCII glyph SHALL be introduced by this feedback.

#### Scenario: Placeholder before the first token
- **WHEN** the user submits a message and no token has arrived yet
- **THEN** the transcript shows the `✻ tether думает…` placeholder with a spinner and the input box's top rule shows the spinner and elapsed seconds

#### Scenario: First delta replaces the placeholder
- **WHEN** the first text or reasoning delta arrives
- **THEN** the placeholder row is gone and the caret is drawn at the end of the newest line

#### Scenario: Text appears before the turn returns
- **WHEN** the model streams an answer
- **THEN** frames painted while the turn is still running already contain the streamed text

#### Scenario: Transitions repaint immediately
- **WHEN** a tool call starts or a tool result arrives
- **THEN** a frame for that event is painted without waiting for the delta throttle

#### Scenario: Cleared when the turn ends
- **WHEN** a turn ends after a reply, an error, or an abort
- **THEN** no placeholder, caret or elapsed field remains, and the input box's top rule is a plain dim rule again

#### Scenario: Confirmation clears the busy state
- **WHEN** a tool call requires confirmation and the menu is raised
- **THEN** the placeholder, caret and elapsed field are cleared while the turn waits for the user

#### Scenario: Caret is not drawn while scrolled up
- **WHEN** the user has scrolled up while deltas are still arriving
- **THEN** no caret is drawn on the newest visible row

#### Scenario: Caret is not drawn while a modal surface owns the keyboard
- **WHEN** the palette, confirmation menu, ask block, or login secret mode is open while deltas arrive
- **THEN** no caret is drawn on the newest visible row

#### Scenario: ASCII mode
- **WHEN** ASCII mode is active during a turn
- **THEN** the spinner uses ASCII frames, the caret is `|`, and no non-ASCII glyph is emitted by the feedback

#### Scenario: No repaint is required while nothing happens
- **WHEN** a tool runs for a long time without producing stream events
- **THEN** the TUI is not required to repaint and the last painted frame stays on screen

#### Scenario: Busy pump handles Enter mid-stream
- **WHEN** the user presses Enter with text while deltas are streaming
- **THEN** the steering queue accepts the message without waiting for the turn to end and without starting a second turn

#### Scenario: Confirmation blocks the pump
- **WHEN** a confirmation menu is open and the user presses Enter
- **THEN** only the confirmation handler acts; no steering message is queued
