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

Rows SHALL be allocated bottom-up: the footer rows are reserved from
the bottom of the screen (see the footer separator requirement for the
exact budget) and the transcript receives every remaining row. No
region SHALL overlap another, and a change in footer height SHALL
change the transcript height by the same number of rows.

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
When the user scrolled up, the TUI SHALL report how many transcript
rows are hidden below as `↓ +N` (ASCII `v +N`). The status line SHALL
show the count, and the newest visible transcript row SHALL
additionally carry the same marker, right-aligned, while following is
off. Returning to the bottom SHALL re-enter follow mode and remove
both indicators. The in-transcript marker SHALL be omitted when the
count is zero, when the row is too narrow to hold it without
truncating the row's own content, and while an overlay is open. The
reported count SHALL stay exact across appends, expansion toggles,
`/clear`, `/new`, and resize.

#### Scenario: Indicator while scrolled up
- **WHEN** the transcript is scrolled up with lines below
- **THEN** the status line shows `↓ +N` with the count

#### Scenario: In-transcript marker
- **WHEN** the user scrolled up and 7 transcript rows are hidden below
- **THEN** the newest visible transcript row ends with `↓ +7` and the status line shows the same count

#### Scenario: Marker hidden at the bottom
- **WHEN** the user is in follow mode at the bottom of the transcript
- **THEN** neither the transcript row nor the status line shows the marker

#### Scenario: ASCII mode renders the marker in ASCII
- **WHEN** ASCII mode is active and the transcript is scrolled up
- **THEN** the marker renders as `v +N` with no non-ASCII glyphs

#### Scenario: No room for the marker
- **WHEN** the newest visible row is too narrow to hold the marker
- **THEN** the marker is omitted and the row content is rendered intact

#### Scenario: Count survives expansion
- **WHEN** the user is scrolled up, expands all tool results, and stays scrolled up
- **THEN** the reported hidden-row count equals the difference between the new transcript height and the viewport bottom


### Requirement: Token usage in status line
The status line SHALL consist of a small fixed set of mandatory parts
rendered in this order, joined by ` · `:
1. `spinner Ns` — only while a turn is busy
2. `model` — the active model name
3. `workspace` — the current workspace path (`~`-abbreviated)
4. `token usage` — `used/max (pct%)` with a `≈` prefix when estimated

Additional flags SHALL NOT be visible by default; they appear only
while relevant:
- `🖱 <mode>` — visible for a short window after the mouse mode
  actually changes, then fades.
- `⌨ <proto>` — visible only when a keyboard protocol is detected
  (non-zero).
- `↓ +N` / `v +N` — the scroll indicator, visible while the user is
  scrolled up.
- The one-shot toast (e.g. `✓ скопировано`) — leads the line while
  active and is cleared by the next keypress.

The status line SHALL stay on a single row; when mandatory parts exceed
the width, overflow SHALL be truncated from the right.

#### Scenario: Default idle line
- **WHEN** no turn is running, no flags are active, and the user is at
  the bottom of the transcript
- **THEN** the status line is `model · ~/workspace · used/max (pct%)`
  with no `🖱`, no `⌨`, no scroll indicator, and no spinner

#### Scenario: Busy turn leads with spinner
- **WHEN** a turn is running and 3 seconds have elapsed
- **THEN** the first part is `spinner 3s` followed by model, workspace,
  and token usage

#### Scenario: Mouse mode shown briefly after change
- **WHEN** the effective mouse mode switches from `auto` to `off`
- **THEN** `🖱 off` is visible in the status line for a few seconds and
  then disappears

#### Scenario: Keyboard protocol shown only when detected
- **WHEN** the TUI negotiated the Kitty keyboard protocol
- **THEN** `⌨ kitty` is visible; when no protocol was detected the
  part is absent

#### Scenario: Summary threshold shown
- **WHEN** token usage reaches `ui.summarize_at`
- **THEN** the status line shows the percentage as a warning

### Requirement: Mouse tracking
When `ui.mouse` is on the TUI SHALL enable SGR mouse reporting
(1006) and interpret clicks and wheel events on the transcript and
palette/confirmation items. A click on a tool row SHALL toggle that entry's
expanded state where the mode delivers transcript clicks (`ui.mouse = "on"`);
in the `auto`, `off` and `selection` modes no transcript click is delivered,
so those modes keep native text selection.

#### Scenario: Wheel scroll
- **WHEN** the mouse wheel is turned over the transcript
- **THEN** the transcript scrolls and follow mode is disabled on
  upward motion

#### Scenario: Click on a tool row
- **WHEN** `ui.mouse = "on"` and the user clicks a collapsed tool row
- **THEN** that entry toggles its expanded state

#### Scenario: No transcript clicks in auto mode
- **WHEN** `ui.mouse = "auto"` and no menu or palette is open and the user clicks a tool row
- **THEN** no transcript entry changes state

### Requirement: Confirmation menu
Out-of-workspace tool calls SHALL show a menu: `[y] once`,
`[a] session`, `[A] always`, `[d] details`, `[n] deny`, `Esc`
cancel; digits 1..6 SHALL map to the same actions in order.

#### Scenario: Digit shortcut
- **WHEN** the user presses `3` on the menu
- **THEN** the `always` decision is taken

### Requirement: Palette
Typing `/` as the first non-blank character of the first input line
SHALL open a command palette listing the available slash entries: the
built-in commands (`/clear /compact /model /resume /new /quit /copy`) in
declared order, followed by the skills discovered by the
context-injection discovery rules, each rendered as `/<name>` in
discovery order. A skill whose name matches a built-in command name
without regard to case SHALL NOT be listed: the command owns that token,
and case SHALL NOT decide which of the two it is.

Each row SHALL render the entry name, its short description, and, after
the name, the entry's argument hint when it has one. A skill row SHALL
show the hint `[задача]`; an entry that takes no arguments SHALL NOT show
a hint.

Filtering SHALL be a case-insensitive subsequence match over the entry
name (the command name or the skill name): prefix matches SHALL rank
above interior matches, ties SHALL keep the list order (commands before
skills, and within each group the declared or discovery order), and an
empty filter SHALL list every entry in that order.

Selection SHALL move with the arrows. Enter on a command row SHALL run
that command; Enter on a skill row SHALL only write `/<name> ` into the
input and close the palette, sending nothing, and the skill body SHALL
NOT be read into the input and SHALL NOT appear in the transcript. Tab
SHALL write the selected entry's `/<name> ` into the input, and Esc SHALL
close the palette leaving the typed text. Enter SHALL act on the
highlighted entry only when the palette holds a match; with no match the
palette SHALL render no rows and Enter SHALL neither run a command nor
submit the input.

The palette SHALL render a window of at most
`min(8, floor(h / 2))` rows, where `h` is the terminal height, and never
fewer than one row. The window SHALL shift so that the selected row is
inside it: entries outside the window SHALL NOT be painted, and the
selected entry SHALL always be painted. When the entry count exceeds the
window, the palette SHALL render a dim `<selected>/<total>` indicator on
the row directly below the last painted entry row, where `<selected>` is
the selected entry's 1-based position in the ranked list and `<total>` is
the number of entries; the indicator SHALL consist of digits and `/`
only, and it SHALL occupy the row the footer budget already reserves for
the palette, so that budget and the separator row do not move. The
indicator SHALL be painted only while that row is inside the palette
region, above the separator; when the terminal is too short for the
region to hold it, the indicator SHALL be omitted, entry rows SHALL keep
their window, and no palette row SHALL be painted over the separator or
the status line.

The palette SHALL close when the filter contains a space or the first
character is no longer `/`. Skill rows SHALL be resolved when the palette
opens and SHALL NOT be re-resolved while it stays open, and a discovery
problem SHALL NOT break the palette or the session: the palette then
holds the commands only.

#### Scenario: Palette open and select
- **WHEN** the user types `/mod`
- **THEN** the palette filters to `/model` and Enter applies it

#### Scenario: Fuzzy match
- **WHEN** the user types `/mdl`
- **THEN** `/model` is listed and selected

#### Scenario: Prefix outranks interior match
- **WHEN** two commands match, one by prefix and one only by an interior subsequence
- **THEN** the prefix match is listed first and is the initial selection

#### Scenario: Empty filter lists everything
- **WHEN** the user types `/`
- **THEN** every declared command is listed in declared order with its description, followed by every discovered skill in discovery order

#### Scenario: No match
- **WHEN** the user types `/zzz` and presses Enter
- **THEN** the palette shows no rows, no command runs, and no message is submitted

#### Scenario: Space closes the palette
- **WHEN** the user types `/model ` (with a trailing space)
- **THEN** the palette closes and the text stays in the input

#### Scenario: Discovered skills are listed after the commands
- **WHEN** two skills are discovered and the user types `/`
- **THEN** the palette lists the commands in declared order and then both skill names in discovery order, each with its description

#### Scenario: A skill is found by typing its name
- **WHEN** skill `deploy` is discovered and the user types `/dep`
- **THEN** `/deploy` is listed and selected

#### Scenario: Selecting a skill only completes the input
- **WHEN** the user selects skill `deploy` and presses Enter
- **THEN** the input holds `/deploy ` and nothing was sent, no body was read, and the transcript is unchanged

#### Scenario: Tab completes a skill name
- **WHEN** the user selects skill `deploy` and presses Tab
- **THEN** the input holds `/deploy ` and no command runs

#### Scenario: A skill colliding with a command is not listed
- **WHEN** skill `Copy` is discovered and the user types `/`
- **THEN** the palette lists the `/copy` command row once and no skill row for that name

#### Scenario: Argument hints are rendered
- **WHEN** the palette renders a skill row and a command row
- **THEN** the skill row shows its `[задача]` hint and the command row shows none

#### Scenario: The window follows the selection
- **WHEN** 20 entries are listed and the user moves the selection to the 10th row
- **THEN** at most 8 rows are painted, the selected row is among them, and the first entry is no longer painted

#### Scenario: Overflow is indicated
- **WHEN** the entry count exceeds the rendered window
- **THEN** the row directly below the painted entries shows a dim `<selected>/<total>` built from digits and `/`

#### Scenario: No indicator while everything fits
- **WHEN** the entry count fits inside the window
- **THEN** no indicator row is painted and every entry row is shown

#### Scenario: A short terminal shrinks the window
- **WHEN** the terminal is 12 rows tall and the palette is open
- **THEN** at most 6 palette rows are painted and the selected row is among them

#### Scenario: No room for the indicator
- **WHEN** the palette region holds room for the entry rows but not for a row below them
- **THEN** the indicator is omitted, the entry rows stay as they are, and no palette row covers the separator or the status line

#### Scenario: Discovery failure degrades
- **WHEN** skill discovery fails and the user types `/`
- **THEN** the palette lists the commands and no skill rows, and the session keeps working

#### Scenario: A skill added later is picked up on the next open
- **WHEN** the palette is open, a new skill directory appears, and the user closes and reopens the palette
- **THEN** the new skill is listed, and while the palette stayed open it was not

#### Scenario: ASCII mode
- **WHEN** ASCII mode is active and the palette renders rows and its overflow indicator
- **THEN** no box-drawing or symbol glyph is emitted by the palette; rows and indicator carry only text, digits and `/`

### Requirement: Skill invocation by name
An input whose first non-blank character is `/` SHALL be dispatched on the
`/<word>` name that starts it. The name SHALL be compared without regard to
case, first with the built-in command names and then with the discovered
skill names. When it names a built-in command, that command SHALL run, so
typing `/CLEAR` behaves like typing `/clear` and agrees with the palette,
which already filters case-insensitively. When it names no built-in command
but names a skill discovered by the context-injection discovery rules, the
input SHALL be submitted to the agent as an ordinary user message: no command
SHALL run, the input SHALL NOT be discarded, the text SHALL reach the agent
verbatim (including the `/<word>` prefix), and no skill body SHALL be
inserted — the agent learns which skill was meant from the skills index in
its system prompt. When it names neither a command nor a skill, the input
SHALL NOT be sent to the agent.

Case SHALL NOT change which name wins: a skill whose name matches a command
name without regard to case is never dispatched, so the command keeps the
token. The comparison SHALL be made at submit time, so a name that no longer
resolves takes the non-skill path.

#### Scenario: A skill name reaches the agent
- **WHEN** skill `deploy` is discovered and the user submits `/deploy выложи на прод`
- **THEN** the message `/deploy выложи на прод` is sent to the agent as a user message, no command runs, and the transcript shows it

#### Scenario: Case does not matter for a skill name
- **WHEN** skill `deploy` is discovered and the user submits `/Deploy выложи на прод`
- **THEN** the message is sent to the agent as a user message, exactly as the lowercase spelling is

#### Scenario: A command name is never dispatched as a skill
- **WHEN** skill `copy` is discovered and the user submits `/COPY`
- **THEN** the copy command runs and the text is not sent to the agent

#### Scenario: An unknown name is not sent to the agent
- **WHEN** the user submits `/nosuchthing`
- **THEN** no message is sent to the agent and the transcript gains no user row



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
### Requirement: Live turn feedback
The TUI SHALL show turn progress while the agent works, without
waiting for the turn to finish. On submit it SHALL paint the waiting
state immediately: the newest transcript row SHALL carry a
`✻ tether думает…` placeholder with a spinner frame, and the status
line SHALL show a spinner with the elapsed seconds of the turn. The
placeholder SHALL disappear with the first `text_delta` or
`reasoning_delta` and SHALL give way to a caret `▌` (ASCII `|`) at
the end of the newest line while deltas keep arriving; the caret
SHALL NOT be drawn while the user has scrolled up or while an
overlay is open. Text and tool progress SHALL become visible during
the turn: the TUI SHALL repaint while the turn is running, throttled
by a bounded number of skipped deltas, and SHALL repaint immediately
on state transitions (tool call start, tool result, error, abort,
confirmation). No background timer SHALL be required: repaints
driven by events and keypresses are sufficient, and the spinner
advances only when the TUI repaints. The waiting placeholder, caret
and elapsed field SHALL be cleared when the turn ends — after a
reply, on error, on abort, and when a confirmation menu is raised
(the turn is then waiting on the user) — and SHALL apply equally to a
turn resumed after a confirmation decision. The elapsed counter
SHALL reset at the start of each turn. In ASCII mode the spinner
SHALL use ASCII frames (the caret is `|`) and no non-ASCII glyph
SHALL be introduced by this feedback.

#### Scenario: Placeholder before the first token
- **WHEN** the user submits a message and no token has arrived yet
- **THEN** the transcript shows the `✻ tether думает…` placeholder with a spinner and the status line shows the spinner and elapsed seconds

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
- **THEN** no placeholder, caret or elapsed field remains

#### Scenario: Confirmation clears the busy state
- **WHEN** a tool call requires confirmation and the menu is raised
- **THEN** the placeholder, caret and elapsed field are cleared while the turn waits for the user

#### Scenario: Caret is not drawn while scrolled up
- **WHEN** the user has scrolled up while deltas are still arriving
- **THEN** no caret is drawn on the newest visible row

#### Scenario: ASCII mode
- **WHEN** ASCII mode is active during a turn
- **THEN** the spinner uses ASCII frames, the caret is `|`, and no non-ASCII glyph is emitted by the feedback

#### Scenario: No repaint is required while nothing happens
- **WHEN** a tool runs for a long time without producing stream events
- **THEN** the TUI is not required to repaint and the last painted frame stays on screen
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

### Requirement: Turn separators
The TUI SHALL insert one dim separator row before each new user turn
in the transcript, carrying the local wall-clock submission time as
`── HH:MM ──` (ASCII `-- HH:MM --`). Separator rows SHALL behave as
transcript rows for scrolling and the transcript height, and SHALL
NOT be sent to the agent or added to the agent history. They SHALL be
controlled by `ui.turn_separators` (default on); with it off no
separator rows are created. The TUI SHALL NOT synthesize separators
for the messages restored by `-r` startup or `/resume`, because no
submission time is available for them. `/clear` SHALL drop separators
together with the rest of the transcript and `/new` SHALL drop them
with the previous session.

#### Scenario: One separator per turn
- **WHEN** the user submits two messages in a session
- **THEN** the transcript holds two separator rows, each immediately before its user row, in chronological order

#### Scenario: Separators carry the submission time
- **WHEN** a message is submitted at 14:32 local time
- **THEN** its separator row reads `── 14:32 ──`

#### Scenario: Disabled by config
- **WHEN** `ui.turn_separators` is false and the user submits a message
- **THEN** no separator row is added and the transcript is unchanged apart from the new turn

#### Scenario: Resume does not invent separators
- **WHEN** the TUI starts with `-r` and restored history holds two user messages
- **THEN** the restored transcript contains no separator rows until the next message is submitted

#### Scenario: ASCII mode
- **WHEN** ASCII mode is active and a turn separator is rendered
- **THEN** it is rendered as `-- HH:MM --` with no non-ASCII glyphs
### Requirement: Path completion
With `ui.path_completion` on (default) and a non-empty input, pressing
Tab outside an open palette SHALL complete the workspace-relative
path token under the cursor against the workspace contents:

- Exactly one candidate SHALL complete the token in place without
  opening the palette, leaving any text that follows the token unchanged.
- Several candidates SHALL open the palette listing them, with the
  first candidate applied to the token so the user sees the current
  choice, and each further Tab press SHALL move to the next candidate
  and apply it, wrapping at the end of the list.
- Directory candidates SHALL be completed with a trailing `/` so that
  completing again lists inside them.
- Esc SHALL close the completion palette and restore the token exactly
  as typed before the first completion.
- Completion SHALL leave the cursor immediately after the text it
  applied: directly after the applied candidate, or directly after the
  token restored by Esc, and in both cases before any text that
  follows the token. The cursor SHALL NOT be placed past the end of
  the input.
- With no candidate the input SHALL be left unchanged and no palette
  SHALL open.
- Candidates SHALL be limited to the workspace: absolute paths, `~`
  and `..` tokens SHALL NOT be completed, and no candidate outside the
  workspace SHALL be listed.
- Hidden entries (a leading `.`) SHALL be offered only when the typed
  token itself starts with `.`.
- The candidate list SHALL be capped at 200 entries; when the cap
  truncates the list the palette SHALL indicate that more candidates
  exist.
- Completion SHALL NOT send anything to the agent and SHALL NOT alter
  the agent history.
- With `ui.path_completion` false, Tab outside the palette SHALL be a
  no-op, as before.

#### Scenario: Unique candidate completes in place
- **WHEN** the input holds `read src/tether/ag` and `src/tether/agent.lua` is the only match
- **THEN** the token becomes `src/tether/agent.lua` and no palette opens

#### Scenario: Text after the token survives a unique completion
- **WHEN** the input holds `read src/tether/ag.bak` with the cursor directly after `ag`, and `src/tether/agent.lua` is the only match
- **THEN** the input becomes `read src/tether/agent.lua.bak` with the cursor directly after `src/tether/agent.lua`, so the next Backspace deletes its last character

#### Scenario: Cursor follows the applied candidate
- **WHEN** the input holds `read src/tether/ag` with the cursor at the end and Tab completes the token
- **THEN** the cursor sits directly after `src/tether/agent.lua`, so the next Backspace deletes its last character

#### Scenario: Cursor follows a cycled candidate
- **WHEN** several candidates exist and the user presses Tab twice
- **THEN** the cursor sits directly after the second candidate, not after any text that follows the token

#### Scenario: Cursor follows the restored token
- **WHEN** the user presses Tab on a token and then Esc
- **THEN** the token is restored and the cursor sits directly after it

#### Scenario: Directory gets a trailing slash
- **WHEN** the token matches exactly one directory `src`
- **THEN** the token becomes `src/`

#### Scenario: Several candidates cycle
- **WHEN** two files match and the user presses Tab twice
- **THEN** the palette lists both and the token holds the second candidate

#### Scenario: Esc restores the typed token
- **WHEN** the user presses Tab on a token, then Esc
- **THEN** the token is exactly what was typed before the Tab press

#### Scenario: Hidden entries need a dot
- **WHEN** the token is `s` and the workspace holds `src` and `.secrets`
- **THEN** only `src` is offered

#### Scenario: Outside the workspace is not completed
- **WHEN** the token is `../etc/pass` and the workspace has no matching entry
- **THEN** the input is unchanged and no candidate outside the workspace is listed

#### Scenario: Disabled
- **WHEN** `ui.path_completion` is false and the user presses Tab outside the palette
- **THEN** the input and the palette state are unchanged
### Requirement: Copy targets
The `/copy` slash command SHALL open a palette of copy targets for the
current session, listed newest-first: the last assistant answer, the
last tool output, the last fenced code block, and the whole
transcript, each row showing the target and its byte size. Targets
without an available source SHALL be omitted, and with an empty
transcript the palette SHALL show no targets. Enter SHALL copy the
highlighted target to the system clipboard through OSC 52 (the
mechanism used by the last-answer shortcut) and SHALL show a
transient confirmation toast `✓ скопировано <size>` (ASCII
`[ok] скопировано <size>`); Esc SHALL close the palette without
copying. `Ctrl+Shift+C` SHALL keep copying the last assistant answer
directly. Copied text SHALL be the target's plain text with no ANSI
escape sequences. The toast SHALL be present in the repaint produced
by the copy action and SHALL be cleared by the next keypress; clearing
it SHALL NOT depend on a background timer.

#### Scenario: Target list is newest-first
- **WHEN** `/copy` is opened after a patch tool call and an assistant answer
- **THEN** the last answer is listed first, followed by the last tool output, the last code block, and the whole transcript

#### Scenario: Missing targets are omitted
- **WHEN** the session has no code block and `/copy` is opened
- **THEN** no code-block row is listed

#### Scenario: Copy writes OSC 52 and confirms
- **WHEN** the user selects a target and presses Enter
- **THEN** an OSC 52 sequence carrying the target's base64 text is written and the frame contains the confirmation toast

#### Scenario: Copied text has no escapes
- **WHEN** the copied target was rendered with color
- **THEN** the copied bytes contain the plain text only

#### Scenario: Last-answer shortcut unchanged
- **WHEN** the user presses `Ctrl+Shift+C`
- **THEN** the last assistant answer is copied without opening a palette

### Requirement: Code block syntax highlighting
Fenced code blocks SHALL be rendered with per-language token coloring
when the fence info string names a supported language: `lua`, `c`
(and `h`), `sh` (and `bash`), `python`, `js` (and `ts`), `go`, `rust`
and `json`. The language name in the fence SHALL match
case-insensitively and SHALL stay visible in the frame. Coloring SHALL
distinguish at minimum comments, string literals, numbers and
language keywords, and SHALL take its colors from the active theme.

Highlighting SHALL NOT change the block's text or geometry: removing
ANSI sequences from the highlighted rows SHALL reproduce the
unhighlighted rendering exactly, and each row's display width SHALL
be identical in both renderings. An unsupported, absent or
non-alphabetic fence info string SHALL render highlighted-free (as
today).

`ui.highlight` SHALL control the feature: `"off"` disables token
coloring, `"on"` enables it whenever color is available, and `"auto"`
(default) enables it when the terminal is color-capable. ASCII mode,
`ui.ascii` forced on, and `NO_COLOR=1` SHALL suppress token coloring
regardless of `ui.highlight`, leaving pure-ASCII output.

Color depth SHALL be negotiated once at startup and SHALL degrade:
24-bit SGR when `COLORTERM` advertises `truecolor` or `24bit`,
otherwise 256-color SGR, otherwise the 16-color palette. Rendering
SHALL stay legible at every depth.

#### Scenario: Lua block is colored
- **WHEN** the assistant emits a ```lua block with a keyword, a string, a comment and a number
- **THEN** those four token kinds are rendered with distinct SGR styling inside the frame

#### Scenario: Stripping color reproduces the plain block
- **WHEN** ANSI sequences are removed from a highlighted block
- **THEN** the result equals the same block rendered with highlighting off

#### Scenario: Fence label is case-insensitive
- **WHEN** the fence reads ```LUA
- **THEN** the block is highlighted as Lua

#### Scenario: Unknown language stays plain
- **WHEN** the fence reads ```brainfuck or has no info string
- **THEN** no token coloring is applied

#### Scenario: Highlight disabled
- **WHEN** `ui.highlight = "off"`
- **THEN** code blocks render with no token coloring

#### Scenario: ASCII and NO_COLOR win
- **WHEN** `NO_COLOR=1` or ASCII mode is active and `ui.highlight = "on"`
- **THEN** the output carries no ANSI sequences and no non-ASCII glyphs

#### Scenario: Truecolor when advertised
- **WHEN** `COLORTERM=truecolor` and highlighting is active
- **THEN** token colors use 24-bit SGR sequences

#### Scenario: Degraded depth
- **WHEN** `COLORTERM` is unset and the terminal reports 256 colors
- **THEN** token colors use 256-color SGR sequences and the block stays readable
### Requirement: Tool row status and failure visibility
Every tool call SHALL occupy a transcript row whose leading marker reports
its state: `✓` for a successful call (ASCII `[ok]`), `✗` for a failed one
(ASCII `[x]`), and the pending indicator while the call runs. The row SHALL
carry the one-line summary (result counts, exit code, change counts) after
the tool name.

A failed call SHALL additionally carry the **first line** of the error text
in the error role, on the same row as the summary, clipped to the same width
budget as any other summary so a long error message cannot make the row wrap
onto a second line. The full error text SHALL become visible through
expansion; while the row is collapsed no further error lines SHALL be
rendered. Failures SHALL be visible without expansion: a failure the user has
to expand to notice does not count as reported.

#### Scenario: Successful row leads with the done glyph
- **WHEN** a `read` call returns 214 lines
- **THEN** the row renders `✓ read` followed by the line-count summary and no error text

#### Scenario: Failure shows its first error line while collapsed
- **WHEN** a `run` call fails with a multi-line stderr and the terminal is 60 columns wide
- **THEN** the collapsed row occupies exactly one row, starts with `✗ run`, and contains the first error line clipped to the row width

#### Scenario: Remaining error lines wait for expansion
- **WHEN** the user expands a failed call whose error text has four lines
- **THEN** the full error text is rendered in the body

#### Scenario: ASCII mode renders the markers in ASCII
- **WHEN** ASCII mode is active and a tool call succeeds
- **THEN** the row starts with `[ok]` and no non-ASCII glyph for the marker

### Requirement: Tool output display sanitization
Before captured tool output is rendered into transcript rows, collapsed or
expanded, the TUI SHALL remove every control sequence except SGR colour
selection: cursor movement, erase-line and erase-screen, carriage returns,
and OSC/DCS sequences (including window-title changes) SHALL NOT reach the
screen. Runs of blank lines in the rendered body SHALL collapse to a single
blank row.

Sanitization SHALL be display-only: the body stored for the model, the body
stored in the session journal, and the text `/copy` reports SHALL remain the
unsanitized result.

SGR colour present in tool output SHALL survive while colour is on, and SHALL
be dropped together with every other escape when colour is off — ASCII mode,
`NO_COLOR=1`, or a theme that emits no colour.

#### Scenario: Progress-bar output cannot scribble over the row
- **WHEN** a `run` result contains carriage returns, erase-line sequences and repeated progress text
- **THEN** the rendered row and body contain the visible text only, with no escape sequence and no second-line overwrite

#### Scenario: Window-title escapes do not reach the screen
- **WHEN** captured output contains an OSC sequence that sets the window title
- **THEN** no part of that sequence is rendered in the transcript

#### Scenario: Blank-line runs collapse
- **WHEN** an expanded body holds several consecutive blank lines
- **THEN** the body renders a single blank row in their place

#### Scenario: Colour from the tool survives
- **WHEN** colour is on and the captured output carries SGR colour
- **THEN** the rendered body keeps that colour

#### Scenario: Colour-off mode strips escapes
- **WHEN** ASCII mode is active or `NO_COLOR=1` is set and the captured output carries SGR colour
- **THEN** the rendered body contains no escape sequence at all

#### Scenario: The model still sees the original output
- **WHEN** a call whose output carries control sequences completes
- **THEN** the body stored for the model equals the unsanitized output

### Requirement: Tool result expansion
Tool result bodies SHALL be collapsed by default. Expansion SHALL be
controlled per entry and for all entries at once:

- A left click on a tool row SHALL toggle that entry, wherever the mouse mode
  delivers transcript clicks (`ui.mouse = "on"`); in `auto`, `off` and
  `selection` modes no transcript click is delivered.
- `Ctrl+O` SHALL toggle the newest tool entry whose rows overlap the
  viewport, falling back to the newest tool entry in the transcript when the
  viewport holds no tool entry.
- `Ctrl+Shift+O` SHALL toggle all entries at once and SHALL clear per-entry
  state.
- On terminals that cannot report the Shift modifier, `Ctrl+O` SHALL keep the
  all-entries meaning, so expand-all is never unreachable.

An entry SHALL have an explicit per-entry state (`expanded`, `collapsed`) or
inherit the all-entries state, which SHALL default to collapsed. Toggling an
entry SHALL set its explicit state to the opposite of its current effective
state; expanding or collapsing all entries SHALL clear per-entry state. The
expanded body SHALL stay subject to the existing per-tool line caps and the
`… (N строк скрыто)` marker, and expansion state SHALL NOT be persisted
between sessions or transmitted to the agent.

#### Scenario: Click toggles one entry
- **WHEN** the mouse mode delivers transcript clicks and the user clicks a collapsed `grep` row
- **THEN** that entry expands and every other tool row keeps its current state

#### Scenario: Ctrl+O toggles the newest visible entry
- **WHEN** the viewport holds two tool rows and the user presses `Ctrl+O`
- **THEN** the newer of those two entries toggles and the older one does not

#### Scenario: Ctrl+O with no tool row in the viewport
- **WHEN** the user is scrolled to a region holding no tool row and presses `Ctrl+O`
- **THEN** the newest tool entry in the transcript toggles, even though it is off-screen

#### Scenario: Ctrl+Shift+O toggles everything
- **WHEN** one entry was expanded by click and the user presses `Ctrl+Shift+O`
- **THEN** all entries expand or all collapse together and the per-entry state is cleared

#### Scenario: Plain terminal keeps expand-all
- **WHEN** no keyboard protocol was negotiated and the user presses `Ctrl+O`
- **THEN** all entries toggle together, as before

#### Scenario: Height stays exact across per-entry toggles
- **WHEN** the user toggles one entry while scrolled up
- **THEN** the transcript height and the hidden-row count reflect the toggled body exactly

### Requirement: Tool body syntax highlighting
Expanded tool bodies SHALL be rendered with the same token colouring used for
fenced code blocks, under the same gates and theme roles. The language SHALL
be taken from the call's own target instead of a markdown fence: a `read`
body follows the read file's extension, each `grep` match follows its own
matched path, and `list`, `glob` and `run` bodies render unhighlighted,
because no language is known for them.

The `lineno<TAB>` prefix of a `read` body and the `path:line:` prefix of a
`grep` body SHALL be excluded from the token colouring and SHALL keep their
current presentation. Highlighting SHALL NOT change the body's text or
geometry: stripping SGR SHALL reproduce the unhighlighted rows exactly, and
each row SHALL have the same display width in both renderings. An unknown or
unsupported extension SHALL render plain. `ui.highlight = "off"`, ASCII mode,
`NO_COLOR=1` and a colour-free theme SHALL suppress token colouring.

#### Scenario: Lua read body is coloured
- **WHEN** a `read` of `src/tether/agent.lua` returns lines with a keyword, a string and a comment and the user expands it
- **THEN** those token kinds are rendered with distinct SGR styling

#### Scenario: The read prefix stays out of the colouring
- **WHEN** a highlighted `read` body is rendered
- **THEN** the line number and the tab that follows it carry no token colour, and the content begins at the same column as in the unhighlighted rendering

#### Scenario: Grep matches follow their own paths
- **WHEN** an expanded `grep` body matches a `.lua` and a `.json` file
- **THEN** each match row is coloured for that file's language

#### Scenario: Operations without a language stay plain
- **WHEN** the user expands a `run` body
- **THEN** no token colouring is applied

#### Scenario: Unknown extension stays plain
- **WHEN** a `read` body comes from a file whose extension is not a supported language
- **THEN** the body renders uncoloured

#### Scenario: Stripping colour reproduces the plain body
- **WHEN** SGR sequences are removed from a highlighted tool body
- **THEN** the result equals the same body rendered with highlighting off, row for row and column for column

#### Scenario: Highlight disabled
- **WHEN** `ui.highlight = "off"` or ASCII mode is active
- **THEN** tool bodies render with no token colouring

### Requirement: Diff rendering for write and patch
The body of a `write` or `patch` result SHALL render as a unified diff: added,
removed and context lines SHALL take the diff roles the theme defines, added
and removed lines SHALL carry old/new line numbers derived from the hunk
headers, and the body SHALL be syntax-highlighted where the target path names
a supported language. A body that does not parse as a unified diff SHALL
render as ordinary text, unchanged by this requirement.

The tool row's summary SHALL report the change as `+N −M` followed by a
proportional meter (`━━━━`; ASCII `#`), where the meter carries at least one
block for each non-zero side and its block counts follow the N:M ratio within
one block. A `write` summary SHALL distinguish a created file from an
overwritten one.

#### Scenario: Expanded write is a diff
- **WHEN** a `write` overwrites `src/app.lua` and the user expands the row
- **THEN** the body renders added lines, removed lines and context with the diff roles, old/new line numbers, and Lua token colouring

#### Scenario: Created file reads as a creation diff
- **WHEN** a `write` creates a file that did not exist
- **THEN** the summary says the file was created and reports `+N −0`

#### Scenario: Patch result renders as a diff
- **WHEN** a `patch` succeeds and the user expands the row
- **THEN** the applied diff is rendered with the diff roles and line numbers

#### Scenario: Meter reflects the ratio
- **WHEN** a change is `+12 −3`
- **THEN** the meter has both added and removed blocks, with the added side visibly longer

#### Scenario: Zero side has no blocks
- **WHEN** a `write` creates a file (`+34 −0`)
- **THEN** the meter shows added blocks only

#### Scenario: Non-diff body stays plain
- **WHEN** a `write` or `patch` result body is not a unified diff
- **THEN** the body renders as ordinary text

#### Scenario: Expansion caps still apply
- **WHEN** a diff body exceeds the configured expanded line cap
- **THEN** the body is capped and the `… (N строк скрыто)` marker reports the remainder

### Requirement: Word-level diff emphasis
Within a rendered diff, a removed line and the added line that replaced it
SHALL be compared word by word, and only the words that actually changed SHALL
keep the added/removed role: carried-over words SHALL be rendered muted so the
change itself stands out.

Pairing SHALL be conservative. Only a removed run and an added run of the same
length, adjacent in the diff, SHALL be paired. A pair whose lines share too
little content SHALL be left unemphasised, because muting incidental
characters would mislead. Pure insertions and pure deletions SHALL be coloured
whole. Lines longer than a documented threshold SHALL skip the comparison
entirely. Emphasis SHALL be expressed through the theme's roles; a theme
without colour SHALL render the diff without word emphasis rather than emit a
bare style.

#### Scenario: Only the changed word is emphasised
- **WHEN** a removed line and the added line that replaces it differ in one argument
- **THEN** that argument keeps the added/removed role in each line and the rest of both lines renders muted

#### Scenario: Unequal runs are not paired
- **WHEN** two removed lines are replaced by one added line
- **THEN** all three lines are coloured whole with no word emphasis

#### Scenario: Dissimilar pair is left alone
- **WHEN** replaced lines share only incidental punctuation
- **THEN** both lines are coloured whole with no word emphasis

#### Scenario: Pure insertion
- **WHEN** an added line has no removed counterpart
- **THEN** the whole line takes the added role

#### Scenario: Very long lines skip the comparison
- **WHEN** a replaced line exceeds the documented length threshold
- **THEN** both lines render with no word emphasis and the row stays on one wrapped segment per line

#### Scenario: Mono theme degrades
- **WHEN** the active theme emits no colour and a diff carries a replaced pair
- **THEN** the diff renders with no word emphasis and no stray escape sequence

### Requirement: Pending change preview
While a `write` or `patch` call is pending — its arguments are known and the
tool has not run — the TUI SHALL render the projected change on that entry
when the agent supplies one, in place of the result body, while the row keeps
its pending marker. The projection SHALL be collapsible and expandable like
any body, SHALL obey the same sanitization, highlighting, diff and line-cap
rules, and SHALL be replaced by the executed result when the call completes.
The preview SHALL be a read-only projection: it SHALL NOT be written to the
transcript history, SHALL NOT be sent to the agent, and SHALL be dropped when
the call is denied, cancelled or aborted.

When no projection is supplied — because the target is outside the workspace,
unreadable, or larger than the documented bound — the pending row SHALL render
as it does today: the pending marker and the tool name, with no diff.

#### Scenario: Pending write shows what will change
- **WHEN** a `write` call is pending with known arguments, the target exists and the user expands the row
- **THEN** the projected diff is rendered before the tool runs

#### Scenario: Pending patch shows the submitted diff
- **WHEN** a `patch` call is pending and awaiting confirmation
- **THEN** the projected diff is rendered on the entry while the menu is open

#### Scenario: No projection falls back to the plain row
- **WHEN** the pending call's target cannot be read or exceeds the document bound
- **THEN** the row shows the pending marker and name only, with no diff

#### Scenario: Result replaces the preview
- **WHEN** the pending call finishes
- **THEN** the entry carries the executed result, and the preview is gone

#### Scenario: Denied call drops the preview
- **WHEN** the user denies a pending call
- **THEN** no preview or result body remains on the entry

### Requirement: Viewport-proportional transcript rendering
A repaint SHALL render only what the viewport needs: the visible rows
plus the transcript entries that partially overlap the viewport. Both
the rendering work and the retained wrapped-line cache SHALL be
bounded by the viewport rather than by session length. The transcript
height SHALL be maintained incrementally, so the scroll indicator,
scroll clamping and follow-mode math do not rescan the transcript on
every repaint, and SHALL stay exact across appends, expand-all
(`Ctrl+Shift+O`) and per-entry expansion (`Ctrl+O`, click), thinking
toggle (`Ctrl+T`), `/clear`, `/new` and resize.
Cached wrapped lines SHALL be evicted for entries that remain
off-screen and re-derived on demand when scrolled back into view,
and cache memory SHALL stay within a documented bound on a long
session. Virtualized rendering SHALL be indistinguishable from a
full render: the same transcript SHALL produce the same visible rows
in the same order, at any scroll offset.

#### Scenario: Parity with a full render
- **WHEN** the same transcript is rendered with virtualization at any scroll offset
- **THEN** the visible rows equal those of a full render of the same transcript

#### Scenario: Long session repaint stays viewport-sized
- **WHEN** a session holds 50,000 transcript rows and the terminal is 24 rows tall
- **THEN** one repaint renders at most the visible rows plus the partially visible entries, and the wrapped-line cache stays within its documented bound

#### Scenario: Expand-all keeps the height exact
- **WHEN** the user expands all tool results while scrolled up
- **THEN** the transcript height and the hidden-row count reflect the expanded content exactly

#### Scenario: Per-entry toggle keeps the height exact
- **WHEN** the user toggles a single entry while scrolled up
- **THEN** the transcript height and the hidden-row count change by exactly that entry's collapsed/expanded row difference

#### Scenario: Resize re-wraps only what is needed
- **WHEN** the terminal is resized
- **THEN** visible rows are re-wrapped to the new width and the height is recomputed without a full-transcript re-render

#### Scenario: Scrolling back restores identical content
- **WHEN** the user scrolls far away from an entry and back to it
- **THEN** its rows are identical to the first render and the cache stayed bounded

### Requirement: Footer separator
The TUI SHALL render a single dim `─`-filled separator row between the
input field and the status line. The separator SHALL be owned by the
layout computation so it stays exact across input-height changes,
palette visibility, error-banner visibility, and terminal resizes.
The separator SHALL be dim in every theme, including `mono` (it is a
static glyph row, not a colored role). In ASCII mode the separator
SHALL use `─` replaced by `-`.

The layout SHALL reserve the footer row by row, counted from the bottom
of the screen, as
`input_h + palette_h + error_h + 1 (separator) + 1 (status)`,
where `input_h = min(#input_lines, ui.input_max_lines)` but never less
than 1, `error_h` is 1 while the error banner is visible and 0
otherwise, and `palette_h` is 0 while no palette is visible. That
reserved count SHALL be the only source of the transcript height, so
the transcript SHALL NOT extend into the footer and no two regions
SHALL claim the same row: every input row SHALL sit strictly above the
separator row, and the separator row strictly above the status line.
The separator row SHALL therefore be reserved even when the input holds
a single line and no palette or error banner is visible.

#### Scenario: Separator sits between input and status
- **WHEN** the TUI renders a normal frame with a non-empty or empty input
- **THEN** the row directly above the status line is a dim rule
  spanning the terminal width

#### Scenario: One-line input keeps its own row
- **WHEN** the TUI renders a frame with a one-line input and neither palette nor error banner
- **THEN** the input row directly above the separator still shows the text the user typed, the separator occupies the next row, and the status line occupies the last row

#### Scenario: Budget follows a growing input
- **WHEN** `ui.input_max_lines` grows the input block from 1 to N visible rows
- **THEN** the transcript height shrinks by N − 1 rows and the input block, separator row, and status line still occupy N + 2 distinct rows

#### Scenario: Palette and error banner stay inside the budget
- **WHEN** the command palette is open and an error banner is visible
- **THEN** the transcript height shrinks by the palette and banner heights, and neither the palette nor the banner overlaps the input block or the separator row

#### Scenario: Separator survives resize and input height change
- **WHEN** the terminal is resized while the input holds several lines
- **THEN** the separator remains a single row between the input block and
  the status line, and the status line still occupies the last row of the
  screen

#### Scenario: Separator in ASCII mode
- **WHEN** ASCII mode is active
- **THEN** the separator uses ASCII `-` instead of `─`
