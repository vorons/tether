# Spec Delta

## MODIFIED Requirements

### Requirement: Screen regions
The TUI SHALL lay out: an optional header (disabled by default),
the scrollable transcript region, and a bottom dock holding the
input box, the optional palette, and the footer. With
`ui.alt_screen = true` the TUI SHALL enter the alternate screen
buffer on start and leave it on exit; with `false` the native
scrollback is kept.

Rows SHALL be allocated bottom-up: the dock rows are reserved from
the bottom of the screen (see the footer requirement for the exact
budget) and the transcript receives every remaining row. No
region SHALL overlap another, and a change in dock height SHALL
change the transcript height by the same number of rows.

Within the dock the rows SHALL run, top to bottom: the input box's
top rule, the input's content rows, its bottom rule, the palette rows
(only while the palette is open), the footer's path row, the footer's
stats row, and the optional flag row.

#### Scenario: alt_screen default
- **WHEN** the user starts the TUI without config
- **THEN** the alternate screen buffer is used

#### Scenario: Dock order
- **WHEN** a frame is rendered with a one-line input and a closed palette
- **THEN** the box's two rules and the footer's two rows are the last four rows of the screen, in that order, with no other region between them

### Requirement: Scroll position indicator
When the user scrolled up, the TUI SHALL report how many transcript
rows are hidden below as `↓ +N` (ASCII `v +N`). The footer's flag row
SHALL show the count, and the newest visible transcript row SHALL
additionally carry the same marker, right-aligned, while following is
off. Returning to the bottom SHALL re-enter follow mode and remove
both indicators. The in-transcript marker SHALL be omitted when the
count is zero, when the row is too narrow to hold it without
truncating the row's own content, and while an overlay is open. The
reported count SHALL stay exact across appends, expansion toggles,
`/clear`, `/new`, and resize.

#### Scenario: Indicator while scrolled up
- **WHEN** the transcript is scrolled up with lines below
- **THEN** the footer's flag row shows `↓ +N` with the count

#### Scenario: In-transcript marker
- **WHEN** the user scrolled up and 7 transcript rows are hidden below
- **THEN** the newest visible transcript row ends with `↓ +7` and the footer's flag row shows the same count

#### Scenario: Marker hidden at the bottom
- **WHEN** the user is in follow mode at the bottom of the transcript
- **THEN** neither the transcript row nor the footer shows the marker

#### Scenario: ASCII mode renders the marker in ASCII
- **WHEN** ASCII mode is active and the transcript is scrolled up
- **THEN** the marker renders as `v +N` with no non-ASCII glyphs

#### Scenario: No room for the marker
- **WHEN** the newest visible row is too narrow to hold the marker
- **THEN** the marker is omitted and the row content is rendered intact

#### Scenario: Count survives expansion
- **WHEN** the user is scrolled up, expands all tool results, and stays scrolled up
- **THEN** the reported hidden-row count equals the difference between the new transcript height and the viewport bottom

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
it, so that budget and the input box's rules do not move. The
indicator SHALL be painted only while that row is inside the palette
region, below the input box's bottom rule; when the terminal is too short
for the region to hold it, the indicator SHALL be omitted, entry rows
SHALL keep their window, and no palette row SHALL be painted over the
input box's rules or the footer's rows.

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
- **THEN** the indicator is omitted, the entry rows stay as they are, and no palette row covers the input box's rules or the footer's rows

#### Scenario: Discovery failure degrades
- **WHEN** skill discovery fails and the user types `/`
- **THEN** the palette lists the commands and no skill rows, and the session keeps working

#### Scenario: A skill added later is picked up on the next open
- **WHEN** the palette is open, a new skill directory appears, and the user closes and reopens the palette
- **THEN** the new skill is listed, and while the palette stayed open it was not

#### Scenario: ASCII mode
- **WHEN** ASCII mode is active and the palette renders rows and its overflow indicator
- **THEN** no box-drawing or symbol glyph is emitted by the palette; rows and indicator carry only text, digits and `/`

### Requirement: Input field and history
The input field SHALL render as a box: one dim rule spanning the
terminal width directly above the input's rows, those rows rendered
with `ui.editor_padding_x` columns of horizontal padding on both
sides, and one dim rule spanning the width directly below them. The
input rows SHALL be padded out to the content width so that both rules
and the text rows have the same display width. The box SHALL NOT draw
side borders and SHALL NOT print a prompt marker inside it: the rules
delimit the input. `ui.editor_padding_x` SHALL be a whole number of
columns, 0 to 3; a larger value SHALL be clamped to 3, a negative one
to 0, and the value SHALL further be clamped so that the content keeps
at least one column. The rules SHALL be dim in every theme, including
`mono` (they are static glyph rows, not colored roles). In ASCII mode
the rules SHALL use `-` instead of `─`.

The caret SHALL be drawn as a reverse-video block: when the cursor
sits on a character, that character SHALL be painted in reverse video
and no other cell SHALL be; when the cursor sits at the end of a row, a
reverse-video space SHALL be painted after the text. The block SHALL be
painted in the TUI's own frame and SHALL be the only caret shown while
the input has focus; the hardware terminal cursor SHALL stay hidden,
except while an overlay needs it. In ASCII mode the block SHALL still
be used, since it is a video attribute and not a glyph.

The input SHALL show at most `ui.input_max_lines` rows at a time,
never fewer than one, and the window SHALL shift to keep the cursor row
inside it. While the window hides rows above the cursor, the top rule
SHALL carry a centered `↑ N more` label (ASCII `^ N more`); while it
hides rows below, the bottom rule SHALL carry a centered `↓ N more`
label (ASCII `v N more`). A scroll label SHALL be omitted when the rule
is too narrow to hold it without losing the rule's own glyphs.

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

#### Scenario: Framed input
- **WHEN** the input holds one line of text
- **THEN** a dim rule spans the width directly above the text row and another directly below it, the text row is padded out to the same width, and no `›` marker is printed

#### Scenario: Block caret on a character
- **WHEN** the input holds `abc` and the cursor sits after `b`
- **THEN** `b` is painted in reverse video and no other cell is

#### Scenario: End-of-line caret
- **WHEN** the cursor is at the end of the row's text
- **THEN** a reverse-video space is painted directly after the last character

#### Scenario: Hardware cursor stays hidden
- **WHEN** any frame is painted while the input has focus
- **THEN** no cursor-show escape is emitted by the input field's rendering

#### Scenario: Padding applied
- **WHEN** `ui.editor_padding_x` is 2
- **THEN** every input row starts and ends with two padding columns and the text never reaches the row's last column

#### Scenario: Scroll labels in the rules
- **WHEN** the input holds more rows than the window and the cursor is on the last row
- **THEN** the top rule carries `↑ N more` with the number of hidden rows above and the bottom rule carries no label

#### Scenario: Scroll label omitted on a narrow rule
- **WHEN** the terminal is narrower than the label needs
- **THEN** the rule renders as an unbroken run of its glyph with no label

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

### Requirement: Live turn feedback
The TUI SHALL show turn progress while the agent works, without
waiting for the turn to finish. On submit it SHALL paint the waiting
state immediately: the newest transcript row SHALL carry a
`✻ tether думает…` placeholder with a spinner frame, and the input
box's top rule SHALL carry the same spinner with the elapsed seconds of
the turn. The
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

While the TUI waits between attempts the input box's top rule SHALL
show the pending retry — the attempt number and the wait in seconds —
in place of the turn's own indicator; the ordinary indicator SHALL
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
- **THEN** the input box's top rule shows the attempt number and the
  60-second wait, and returns to the ordinary turn indicator when the
  next attempt starts

#### Scenario: Painted without a keypress
- **WHEN** a retry or continuation event arrives
- **THEN** the row is painted while the turn is still running, without
  requiring a keypress

#### Scenario: Retry rows are not agent input
- **WHEN** the retry row is on screen and the turn continues
- **THEN** nothing from the row reaches the agent or its history

#### Scenario: ASCII mode
- **WHEN** ASCII mode is active during a retry
- **THEN** the retry row and the top-rule notice use ASCII glyphs and
  introduce no non-ASCII character

## ADDED Requirements

### Requirement: Footer
The TUI SHALL render the footer as dim rows below the input box and
SHALL NOT use a reverse-video row for it.

The first footer row SHALL carry the workspace path with a leading
`$HOME` abbreviated to `~`, and SHALL be truncated from the right with
a dim `...` when it exceeds the width.

The second footer row SHALL carry on its left, joined by a single
space: the session's accumulated input tokens as `↑<count>`, its
accumulated output tokens as `↓<count>` (each omitted while zero), and
the context cell `used/max (pct%)`; and the model name right-aligned on
the same row, at least two columns away from the left side. Counts
SHALL use the compact form: plain below 1000, one decimal with `k`
below 10000, a rounded `k` below 1000000, and `M` above. The model name
SHALL end in the row's last column whenever both sides fit; when they
cannot both fit, the model name SHALL be truncated from its left so its
tail survives, and dropped entirely only when nothing of it fits. The
left side SHALL be truncated from the right with `...` only when it
alone exceeds the width.

The footer SHALL have an optional third row carrying the active flags
joined by a single space — the one-shot toast, the mouse-mode flag, the
keyboard-protocol flag, and the scroll indicator — and SHALL exist only
while at least one flag is active. That row SHALL be truncated from the
right with a dim `...` and SHALL NOT be dim as a whole, because its
flags carry their own presentation.

The footer's rows SHALL be counted in display columns: wide East-Asian
characters count as 2 and ANSI sequences as 0. In ASCII mode the token
arrows SHALL render as `^` and `v`, and no non-ASCII glyph SHALL be
introduced by the footer.

#### Scenario: Idle footer
- **WHEN** no turn is running, no flag is active, and the session has used 3000 input and 1000 output tokens
- **THEN** the first row is the `~`-abbreviated workspace, the second row starts with `↑3.0k ↓1.0k` followed by the context cell and ends with the model name, and no third row is painted

#### Scenario: Model is right-aligned
- **WHEN** the model name fits beside the left side
- **THEN** it ends in the last column of the stats row and at least two blank columns separate it from the left side

#### Scenario: Counters accumulate across turns
- **WHEN** one turn reports 1200 prompt and 300 completion tokens and a later turn reports 800 and 200
- **THEN** the counters read `↑2.0k` and `↓500`

#### Scenario: Context cell keeps its thresholds
- **WHEN** token usage reaches `ui.summarize_at`
- **THEN** the context cell is rendered as a warning, and at 90% or more as an error

#### Scenario: Flags row appears while active
- **WHEN** the mouse mode has just changed and the transcript is scrolled up
- **THEN** a third row carries both flags separated by one space, and it disappears once they expire

#### Scenario: No reverse video
- **WHEN** any footer row is rendered
- **THEN** no footer row uses reverse video and the path and stats rows are dim

#### Scenario: Narrow terminal drops the model name
- **WHEN** the model name cannot fit beside the left side of the stats row
- **THEN** the left side is rendered intact and the model name is truncated from its left, or omitted if nothing of it fits

#### Scenario: ASCII mode
- **WHEN** ASCII mode is active and counters are shown
- **THEN** the arrows render as `^` and `v` and the footer introduces no non-ASCII glyph

## REMOVED Requirements

### Requirement: Footer separator
**Reason**: The separator row is subsumed by the input box's bottom rule, and the reverse-video status row it separated the input from no longer exists.

**Migration**: The input box's bottom rule now delimits the input, and `Screen regions` plus `Footer` own the row budget. No configuration change is required.

### Requirement: Token usage in status line
**Reason**: The reverse-video status line is replaced by the footer, which splits its content across the path row, the stats row and the flag row.

**Migration**: `Footer` carries the token counters, the context cell with the same green/yellow/red thresholds, the model name and the active flags; `Scroll position indicator` now names the footer's flag row.
