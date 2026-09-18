# Spec Delta

## MODIFIED Requirements

### Requirement: Input field and history
The input field SHALL support multi-line editing up to
`ui.input_max_lines` (default 8) with UTF-8-aware cursor movement.
History navigation SHALL work as follows:
- Up/Down with a non-empty input moves the cursor between input
  lines, or scrolls the transcript when at a cursor edge.
- Up/Down with an empty input SHALL scroll the transcript (Up
  scrolls up, Down scrolls down and re-enters follow mode at the
  bottom).
- An explicit history key (Ctrl+Up / Ctrl+Down) SHALL recall
  previously sent messages one entry per press, most-recent first,
  continuing past the most recent entry on repeated presses.
- The recall list SHALL contain only messages that were committed
  to the agent; text typed and discarded without submission SHALL
  not enter the list.

#### Scenario: Scroll with empty input
- **WHEN** the input is empty and Up is pressed
- **THEN** the transcript scrolls up one line; no history text is
  inserted

#### Scenario: Recall walks the list
- **WHEN** Ctrl+Up is pressed three times with five committed
  messages
- **THEN** the input holds the 3rd-most-recent message

#### Scenario: Up with empty input no longer recalls
- **WHEN** the input is empty and Up is pressed
- **THEN** the transcript scrolls up; no history text is inserted
  (replaces the old "Up recalls last prompt" scenario)

#### Scenario: Up recalls last prompt
- **WHEN** the user previously sent a message and the input is empty
- **THEN** Up scrolls the transcript instead of inserting the last
  history text; recall moved to the explicit history key

#### Scenario: Discarded text not recorded
- **WHEN** the user types a line and clears it without Enter
- **THEN** it never appears in subsequent recall

### Requirement: Confirmation menu
Out-of-workspace tool calls SHALL show a menu: `[y] once`,
`[a] session`, `[A] always`, `[d] details`, `[n] deny`, `Esc`
cancel; digits 1..6 SHALL map to the same actions in order.

#### Scenario: Digit shortcut
- **WHEN** the user presses `3` on the menu
- **THEN** the `always` decision is taken

### Requirement: Help overlay
Pressing `?` SHALL show a keybinding help overlay; Esc closes it.

#### Scenario: Help toggle
- **WHEN** `?` is pressed in the input field
- **THEN** the overlay is shown and Esc dismisses it without
  submitting

### Requirement: Error banner and overlay
On an agent or API error the TUI SHALL show a one-line error banner
above the input. Pressing Enter on the banner SHALL open the full
error overlay; Esc or Enter in that overlay SHALL dismiss it and
clear it, after which the input field SHALL accept a new message
immediately without further steps. While the overlay is open,
other input is routed to the overlay (modal); it SHALL NOT block
sending a new message once dismissed.

#### Scenario: Dismiss and send
- **WHEN** an error occurred, the user opens the overlay, presses
  Esc, types a new message, and presses Enter
- **THEN** the new message is sent to the agent

#### Scenario: Banner persists until next submit
- **WHEN** an error banner is showing and the user submits a new
  message without opening the overlay
- **THEN** the banner clears as part of the submit
- **WHEN** an error occurred, the user opens the overlay, presses
  Esc, types a new message, and presses Enter
- **THEN** the new message is sent to the agent

#### Scenario: Banner persists until next submit
- **WHEN** an error banner is showing and the user submits a new
  message without opening the overlay
- **THEN** the banner clears as part of the submit
