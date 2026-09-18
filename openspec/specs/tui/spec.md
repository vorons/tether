# tui

## Purpose

The interactive terminal UI: screen layout regions, markdown-lite
transcript rendering, mouse tracking, slash-command palette, input
history, status line, themes, ASCII fallback, and overlays.


## Requirements

### Requirement: Screen regions
The TUI SHALL lay out: an optional header (disabled by default),
the scrollable transcript region, a status line, and a bottom
input field. With `ui.alt_screen = true` the TUI SHALL enter the
alternate screen buffer on start and leave it on exit; with `false`
the native scrollback is kept.

#### Scenario: alt_screen default
- **WHEN** the user starts the TUI without config
- **THEN** the alternate screen buffer is used

### Requirement: Markdown-lite rendering
Assistant text SHALL render inline code, bold, italic, lists, and
headings; fenced code blocks SHALL render inside a bordered frame
using box-drawing characters (or ASCII in ascii mode). Text SHALL
word-wrap to the terminal width when `ui.wrap` is on.

#### Scenario: Code block framed
- **WHEN** the assistant emits a fenced ```lua block
- **THEN** it renders inside a box-drawing border; text inside is
  not word-wrapped

### Requirement: Streaming append
Assistant text SHALL append incrementally as SSE deltas arrive;
the transcript region SHALL auto-scroll to the bottom while the
agent is streaming.

#### Scenario: Auto-scroll during stream
- **WHEN** the agent is streaming and the user has not scrolled up
- **THEN** the viewport tracks the bottom of the transcript

### Requirement: Token usage in status line
The status line SHALL show current token usage and a percentage of
`ui.summarize_at` when it is set.

#### Scenario: Summary threshold shown
- **WHEN** token usage reaches `ui.summarize_at`
- **THEN** the status line shows the percentage as a warning

### Requirement: Mouse tracking
When `ui.mouse` is on the TUI SHALL enable SGR mouse reporting
(1006) and interpret clicks and wheel events on the transcript and
palette/confirmation items.

#### Scenario: Wheel scroll
- **WHEN** the mouse wheel is turned over the transcript
- **THEN** the transcript scrolls and follow mode is disabled on
  upward motion

### Requirement: Confirmation menu
Out-of-workspace tool calls SHALL show a menu: `[y] once`,
`[a] session`, `[A] always`, `[d] details`, `[n] deny`, `Esc`
cancel; digits 1..6 SHALL map to the same actions in order.

#### Scenario: Digit shortcut
- **WHEN** the user presses `3` on the menu
- **THEN** the `always` decision is taken

### Requirement: Palette
A trigger (`/`) SHALL open a command palette of slash commands
(`/clear /compact /model /resume /new /quit` and help content),
filterable by typing, selectable with arrows/Enter.

#### Scenario: Palette open and select
- **WHEN** the user types `/mod`
- **THEN** the palette filters to `/model` and Enter applies it

### Requirement: Help overlay
Pressing `?` SHALL show a keybinding help overlay; Esc closes it.

#### Scenario: Help toggle
- **WHEN** `?` is pressed in the input field
- **THEN** the overlay is shown and Esc dismisses it without
  submitting

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

#### Scenario: Up recalls last prompt (superseded)
- **WHEN** the user previously sent a message and the input is empty
- **THEN** Up scrolls the transcript instead of inserting the last
  history text; recall moved to the explicit history key

#### Scenario: Discarded text not recorded
- **WHEN** the user types a line and clears it without Enter
- **THEN** it never appears in subsequent recall

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

### Requirement: Themes
The TUI SHALL support a set of named themes applied to roles,
code, and system lines; `ui.theme` selects the active one.

#### Scenario: Theme switch
- **WHEN** the user changes `ui.theme` in config and restarts
- **THEN** the new theme is applied to the next render

### Requirement: Keyboard protocol negotiation
On start the TUI SHALL probe the terminal and enable the Kitty
keyboard protocol when supported (kitty/ghostty/wezterm); otherwise
fall back to modifyOtherKeys / xterm fallback sequences.

#### Scenario: Kitty protocol active
- **WHEN** the terminal advertises Kitty keyboard protocol support
- **THEN** the TUI enables it and keys carry modifier state in the
  CSI u encoding
