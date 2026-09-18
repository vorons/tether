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
word-wrap to the terminal width when `ui.wrap` is on: prose wraps
on word boundaries (greedy), and fenced code blocks soft-wrap
inside the frame with a continuation indent instead of truncating.
No visible content SHALL be lost to truncation when `ui.wrap` is
on. A single token longer than the available width (no spaces to
break on) SHALL be cut hard. Wrap width SHALL be counted in
display columns (wide East-Asian characters count as 2, ANSI
sequences as 0). When `ui.wrap` is off, lines SHALL be truncated
with a cut marker as before.

#### Scenario: Code block framed
- **WHEN** the assistant emits a fenced ```lua block
- **THEN** it renders inside a box-drawing border; long lines inside soft-wrap within the frame instead of truncating

#### Scenario: Prose wraps on word boundaries
- **WHEN** the assistant emits a sentence longer than the transcript width
- **THEN** no line breaks inside a word; the break falls on a space, and every rendered line fits the width

#### Scenario: Code block soft-wraps inside the frame
- **WHEN** the assistant emits a fenced block with a line longer than the frame inner width
- **THEN** the line renders on several framed lines with a continuation indent, the full content stays visible, and no cut marker appears

#### Scenario: Wide characters count double
- **WHEN** text contains East-Asian wide characters
- **THEN** wrapping accounts 2 columns per such character and no line overflows the width

#### Scenario: Overlong token is cut hard
- **WHEN** a single token without spaces exceeds the available width
- **THEN** it is cut hard at the width boundary

#### Scenario: Wrap off still truncates
- **WHEN** `ui.wrap` is off and a line exceeds the width
- **THEN** the line renders truncated to one row with the cut marker

### Requirement: Streaming append
Assistant text SHALL append incrementally as SSE deltas arrive;
the transcript region SHALL auto-scroll to the bottom while the
agent is streaming.

#### Scenario: Auto-scroll during stream
- **WHEN** the agent is streaming and the user has not scrolled up
- **THEN** the viewport tracks the bottom of the transcript

### Requirement: Transcript restore on resume
Resuming a session SHALL restore the visible transcript from the
restored history, showing only user messages and assistant text
(system prompts, tool-call scaffolding and tool results stay in
the agent history, not on screen):
- On `-r` startup the transcript SHALL be seeded from the restored
  agent history followed by a resumed-session marker.
- `/resume` SHALL replace the visible transcript with the picked
  session (not append to it) followed by a resumed-session marker.

#### Scenario: Startup resume seeds transcript
- **WHEN** the TUI starts with restored history holding a user
  message and an assistant reply
- **THEN** both appear in the transcript plus a resumed marker

#### Scenario: Resume picker replaces transcript
- **WHEN** the user picks a session in `/resume` with a
  non-empty current transcript
- **THEN** the old entries are dropped and only the picked
  session's messages are shown

### Requirement: Session commands transcript semantics
- `/new` SHALL drop both the agent history and the visible
  transcript, leaving only a new-session banner.
- `/clear` SHALL clear the transcript display only; the agent
  keeps its history, so the next turn still sees full context.
- `/compact` SHALL append a summary line to the transcript
  after compressing the agent history.

#### Scenario: New session starts clean
- **WHEN** the user runs `/new` with a non-empty transcript
- **THEN** only the new-session banner remains on screen

#### Scenario: Clear keeps agent context
- **WHEN** the user runs `/clear` and then sends a message
- **THEN** the agent answers with full prior history while the
  screen shows only the new exchange

### Requirement: Scroll position indicator
When the user scrolled up, the status line SHALL show how many
transcript lines are hidden below as `↓ новые +N`; returning to
the bottom SHALL re-enter follow mode and hide the indicator.

#### Scenario: Indicator while scrolled up
- **WHEN** the transcript is scrolled up with lines below
- **THEN** the status line shows `↓ новые +N` with the count

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
