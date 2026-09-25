# tui

## Purpose

The interactive terminal UI: screen layout regions, markdown-lite
transcript rendering, mouse tracking, slash-command palette, input
history, status line, themes, ASCII fallback, confirmation menu,
error banner, and masked login secret mode. The palette is the only
list/selection surface; there is no full-screen overlay mechanism.

## Requirements

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
(only while the palette is open), and the footer's single row.

#### Scenario: alt_screen default
- **WHEN** the user starts the TUI without config
- **THEN** the alternate screen buffer is used

#### Scenario: Dock order
- **WHEN** a frame is rendered with a one-line input and a closed palette
- **THEN** the box's two rules and the footer's single row are the last three rows of the screen, in that order, with no other region between them

### Requirement: Markdown-lite rendering
Assistant text SHALL render inline code, bold, italic, ordered and unordered
lists, tables, and headings; fenced code blocks SHALL render inside a bordered
frame using box-drawing characters (or ASCII in ascii mode). Inline code,
bold and italic SHALL take role colours from the active theme (`code`, `bold`,
`italic`). Headings SHALL be wrapped to the width and SHALL take the `heading`
role colour. Tables SHALL be detected from consecutive source lines beginning
with `|`: columns SHALL be left-aligned to the widest cell, a separator row
(`| --- |`) SHALL render as a dim rule, and the rendered block SHALL be clipped
to the terminal width. Ordered lists (`1. `) SHALL be parsed alongside the
existing `-`/`*` items; list items SHALL use a two-column prefix (`• ` in
unicode, `- ` in ascii) and a two-column continuation indent. Runs of blank
lines in the source SHALL collapse to a single blank row, and leading and
trailing blank rows SHALL be dropped.

Text SHALL word-wrap to the terminal width when `ui.wrap` is on: prose wraps on
word boundaries (greedy), and fenced code blocks soft-wrap inside the frame
with a continuation indent instead of truncating. No visible content SHALL be
lost to truncation when `ui.wrap` is on. A single token longer than the
available width (no spaces to break on) SHALL be cut hard. Wrap width SHALL be
counted in display columns (wide East-Asian characters count as 2, ANSI
sequences as 0). When `ui.wrap` is off, lines SHALL be truncated with a cut
marker as before.

#### Scenario: Code block framed

- **WHEN** the assistant emits a fenced ```lua block
- **THEN** it renders inside a box-drawing border; long lines inside soft-wrap within the frame instead of truncating

#### Scenario: Code block frame is closed and labelled

- **WHEN** a fenced block of any inner width is rendered
- **THEN** the top border, the body side rails, and the bottom border all share the same display width (no one-off narrow top edge) and the language label is visible on the top border

#### Scenario: Inline markup is coloured

- **WHEN** the assistant emits `code`, **bold** or *italic*
- **THEN** each is rendered with its theme role colour (`code`, `bold`, `italic`) and no backtick or asterisk markers remain

#### Scenario: Headings wrap and are coloured

- **WHEN** the assistant emits a `# Heading` wider than the transcript width
- **THEN** it wraps to several lines and takes the `heading` role colour

#### Scenario: Tables align

- **WHEN** the assistant emits a `| a | b |` table with a `| --- | --- |` separator row
- **THEN** columns are left-aligned to the widest cell, the separator renders as a dim rule, and the block fits the width

#### Scenario: Ordered lists parse

- **WHEN** the assistant emits `1. first` / `2. second`
- **THEN** each item renders with a numbered prefix and a continuation indent aligned to the prefix width

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

#### Scenario: Blank lines collapse

- **WHEN** the source contains several consecutive blank lines or a trailing blank line
- **THEN** they collapse to a single blank row and no leading or trailing blank row is rendered

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
- `/new` SHALL drop both the agent history and the visible transcript, leaving only a new-session banner.
- `/clear` SHALL clear the transcript display only; the agent keeps its history, so the next turn still sees full context.
- `/compact` SHALL force an immediate compaction (ignoring the threshold) and append a summary line to the transcript. Optional free text after `/compact` SHALL be passed to the summary request as focus instructions. On LLM success the row SHALL show the generated summary (or its stable marker when empty); on fallback the existing `── summary ──` row behavior applies.
- `/login [provider]` and `/logout [provider]` SHALL be registered as built-in slash commands: `/login` with a named provider starts the login flow for that provider; `/login` with no argument opens a provider picker in the shared palette (same mechanism as the slash menu / `/copy` — never a full-screen overlay, never a silent default). Selecting a provider enters login secret mode (`S.login_secret = { buf }`): the secret buffer owns the keyboard while open, is masked on screen, and never appears in `S.input` or a transcript row (see Login secret mode). `/logout` clears the stored credential for the named or active provider. Neither command SHALL print token material to the transcript. Unknown provider names SHALL show an error banner. The palette listing SHALL include both commands with short descriptions.
- `/think [level]` SHALL be registered as a built-in slash command for the reasoning level (`off`, `low`, `medium`, `high`): with a level argument it SHALL apply that level directly; with no argument it SHALL open a level picker in the shared palette, the same mechanism as `/model` (never a full-screen overlay, never a silent default). Applying a level SHALL set the effective `reasoning`, persist it to `~/.tether/config.lua` (best-effort, like the model pick), and append a system row echoing the choice (`→ мышление: medium`). An unknown level SHALL show an error banner and change nothing. The palette listing SHALL include `/think` with a short description.

#### Scenario: New session starts clean
- **WHEN** the user runs `/new` with a non-empty transcript
- **THEN** only the new-session banner remains on screen

#### Scenario: Clear keeps agent context
- **WHEN** the user runs `/clear` and then sends a message
- **THEN** the agent answers with full prior history while the screen shows only the new exchange

#### Scenario: Login appears in palette
- **WHEN** the user opens the slash palette
- **THEN** `/login` and `/logout` are listed among the built-in commands

#### Scenario: Logout line has no secrets
- **WHEN** the user runs `/logout`
- **THEN** a confirmation line appears and contains no token, refresh token, or key text

#### Scenario: Compact with focus instructions
- **WHEN** the user runs `/compact keep the API contract details`
- **THEN** compaction runs immediately, the summary request includes that focus text, and the transcript gains a summary row

#### Scenario: Compact reports fallback
- **WHEN** `/compact` runs and the summary request fails
- **THEN** the transcript still gains a `── summary ──` row (truncation fallback) and no error banner is raised for the summary failure alone

#### Scenario: /think appears in palette
- **WHEN** the user opens the slash palette
- **THEN** `/think` is listed among the built-in commands with its short description

#### Scenario: Direct level apply
- **WHEN** the user runs `/think high`
- **THEN** the effective level becomes `high`, it is persisted to `config.lua`, and the transcript gains a `→ мышление: high` row

#### Scenario: Bare /think opens the level picker
- **WHEN** the user runs `/think` and picks `medium` in the palette
- **THEN** the palette closes, the effective level becomes `medium`, and the transcript gains a `→ мышление: medium` row; Esc instead closes it and changes nothing

#### Scenario: Unknown level is rejected
- **WHEN** the user runs `/think turbo`
- **THEN** an error banner names the bad level and the effective level is unchanged

### Requirement: Scroll position indicator
When the user scrolled up, the TUI SHALL report how many transcript
rows are hidden below as `↓ +N` (ASCII `v +N`) on the footer's single
row while following is off. Returning to the bottom SHALL re-enter
follow mode and remove the indicator. No marker SHALL be painted
inside the transcript. The indicator SHALL be omitted when the count
is zero. The reported count SHALL stay exact across appends,
expansion toggles, `/clear`, `/new`, and resize.

#### Scenario: Indicator while scrolled up
- **WHEN** the transcript is scrolled up with lines below
- **THEN** the footer shows `↓ +N` with the count and no transcript row carries a scroll marker

#### Scenario: In-transcript marker
- **WHEN** the user scrolled up and 7 transcript rows are hidden below
- **THEN** no transcript row ends with a scroll marker; only the footer shows `↓ +7`

#### Scenario: Marker hidden at the bottom
- **WHEN** the user is in follow mode at the bottom of the transcript
- **THEN** the footer does not show the scroll indicator

#### Scenario: ASCII mode renders the marker in ASCII
- **WHEN** ASCII mode is active and the transcript is scrolled up
- **THEN** the footer indicator renders as `v +N` with no non-ASCII glyphs

#### Scenario: No room for the marker
- **WHEN** the footer row is too narrow to hold the scroll indicator beside the left content
- **THEN** the indicator is omitted or truncated per the footer truncation order and the row content is rendered intact

#### Scenario: Count survives expansion
- **WHEN** the user is scrolled up, expands all tool results, and stays scrolled up
- **THEN** the reported hidden-row count equals the difference between the new transcript height and the viewport bottom

### Requirement: Mouse tracking
When `ui.mouse` is `on` — or `auto` (the default) — the TUI SHALL enable SGR
mouse reporting (1006) continuously and interpret clicks and wheel events on
the transcript and palette/confirmation items. The always-on capture in `auto`
exists because the wheel must scroll the transcript: with tracking off,
terminals translate wheel ticks into Up/Down arrow keys, which recall input
history into the field. Transcript click-to-expand is still delivered only
where the mode says so (`ui.mouse = "on"`); `off` and `selection` disable
tracking entirely and keep native text selection.

#### Scenario: Wheel scroll
- **WHEN** the mouse wheel is turned over the transcript
- **THEN** the transcript scrolls — upward toward older rows, downward back
  toward the bottom — and follow mode is disabled on upward motion

#### Scenario: Wheel capture in auto mode
- **WHEN** `ui.mouse = "auto"` (default) and the wheel is turned with no menu or palette open
- **THEN** the transcript scrolls and no input-history text is inserted into the field

#### Scenario: Wheel scroll while the agent is busy
- **WHEN** a turn is running (streaming or a silent wait such as a retry backoff)
  and the wheel is turned
- **THEN** the transcript scrolls during the turn; the running turn is not
  affected and the input is not modified

#### Scenario: Click on a tool row
- **WHEN** `ui.mouse = "on"` and the user clicks a collapsed tool row
- **THEN** that entry toggles its expanded state

#### Scenario: No transcript clicks in auto mode
- **WHEN** `ui.mouse = "auto"` and no menu or palette is open and the user clicks a tool row
- **THEN** no transcript entry changes state

### Requirement: Confirmation menu
Out-of-workspace tool calls SHALL show a menu: `[y] once`,
`[a] session`, `[A] always`, `[n] deny`, `Esc` cancel; digits 1..5
SHALL map to the same actions in order (`1..5` = allow, session,
always, deny, cancel). There SHALL be no `details` option, no `[d]`
binding, and no separate diff view: the projected diff is the pending
tool-row in the transcript, and the result body is available through
expansion. Every decision (including Esc) SHALL clear the menu.

#### Scenario: Digit shortcut
- **WHEN** the user presses `3` on the menu
- **THEN** the `always` decision is taken

#### Scenario: Digit 4 is deny, not details
- **WHEN** the user presses `4` on the menu
- **THEN** the `deny` decision is taken and no overlay or details pane opens

#### Scenario: d is unbound
- **WHEN** the user presses `d` on the menu
- **THEN** the menu stays open and no details view opens

#### Scenario: Esc cancels
- **WHEN** the user presses Esc on the menu
- **THEN** the turn is cancelled and the menu is gone

### Requirement: Palette
Typing `/` as the first non-blank character of the first input line
SHALL open a command palette listing the available slash entries: the
built-in commands (`/clear /compact /model /resume /new /quit /copy
/login /logout /think`) in
declared order, followed by the skills discovered by the
context-injection discovery rules, each rendered as `/<name>` in
discovery order. A skill whose name matches a built-in command name
without regard to case SHALL NOT be listed: the command owns that token,
and case SHALL NOT decide which of the two it is.

Each row SHALL render the entry name, its short description, and, after
the name, the entry's argument hint when it has one. A skill row SHALL
show the hint `[skill]`; an entry that takes no arguments SHALL NOT show
a hint. The name column SHALL be padded to the widest name+hint across
all listed entries so command and skill descriptions align in the same
column.

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
- **THEN** the skill row shows its `[skill]` hint and the command row shows none

#### Scenario: Descriptions align
- **WHEN** the palette lists both commands and skills
- **THEN** every description starts at the same column regardless of the name length or the `[skill]` hint

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

While secret mode is open, the input box SHALL render the masked secret
label instead of `S.input` (see Login secret mode).

The caret SHALL be drawn as a reverse-video block: when the cursor
sits on a character, that character SHALL be painted in reverse video
and no other cell SHALL be; when the cursor sits at the end of a row, a
reverse-video space SHALL be painted after the text. The block SHALL be
painted in the TUI's own frame and SHALL be the only caret shown while
the input has focus; the hardware terminal cursor SHALL stay hidden
for the whole session. In ASCII mode the block SHALL still
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
Editing keys SHALL operate on whole characters, never single bytes:
- Left SHALL move the caret back one character; Right SHALL move it
  forward one character.
- Backspace SHALL delete the whole character before the caret.
- Delete SHALL delete the whole character after the caret.
- The cursor position SHALL always sit on a character boundary (a
  leading byte or the end of the text), never on a continuation byte:
  vertical cursor moves that carry the byte column to a line where it
  lands inside a multi-byte character SHALL snap the column to the
  nearest character boundary on that line.
- None of these keys SHALL raise an error on a mid-character cursor
  position (which can arise from a kill, paste, or completion restore):
  Left/Backspace SHALL treat the cursor as sitting inside the character
  containing it and step/delete from that character's boundary.
History navigation SHALL work as follows:
- Up/Down SHALL recall previously sent messages one entry per press,
  most-recent first, continuing past the most recent entry on repeated
  presses. Down below the newest entry SHALL clear the input.
- Ctrl+Up / Ctrl+Down SHALL recall history exactly like Up/Down (at a
  multi-line edge this discards nothing: recall starts from the
  committed history, and the in-progress draft is not preserved —
  accepted behavior; move the cursor with Shift+Up/Shift+Down instead).
- Inside a multi-line input Up/Down SHALL move the cursor between input
  lines instead of recalling history; Shift+Up/Shift+Down SHALL move the
  cursor explicitly. On terminals without kitty keyboard protocol or
  modifyOtherKeys the terminal reports Shift+Up/Shift+Down as plain
  Up/Down — indistinguishable and accepted; the recall behavior of
  plain Up/Down applies.
- Transcript scrolling SHALL live on PgUp/PgDn, never on Up/Down.
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

#### Scenario: Backspace deletes a whole multi-byte character
- **WHEN** the input holds `привет` with the cursor at the end and the user presses Backspace
- **THEN** the input becomes `приве` and the cursor sits before the (removed) `т`'s position, with both bytes of the 2-byte character removed

#### Scenario: Delete removes the character after the caret
- **WHEN** the input holds `привет` with the cursor at the start and the user presses Delete
- **THEN** the input becomes `ривет` with the cursor still at the start, both bytes of the 2-byte `п` removed

#### Scenario: Vertical move snaps the column to a character boundary
- **WHEN** a multi-line input holds `abc` then `привет` on the next line, the cursor sits after `c` on the first line, and the user presses Up
- **THEN** the cursor snaps to a character boundary on the `привет` line (after `п`'s character boundary nearest to the carried column), never onto a continuation byte

#### Scenario: Editing keys survive a mid-character cursor
- **WHEN** the cursor sits on a continuation byte of a multi-byte character and the user presses Left, Backspace, or Delete
- **THEN** the editor does not raise or crash: Left/Backspace act from that character's start boundary and Delete removes the character containing the cursor byte

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

#### Scenario: Scroll with PgUp
- **WHEN** the transcript is scrolled up and PgUp is pressed
- **THEN** the transcript scrolls further up; no history text is inserted

#### Scenario: Up recalls the newest entry
- **WHEN** the user previously sent a message and the input is empty
- **THEN** Up inserts the most recent history entry; PgUp scrolls the transcript

#### Scenario: Down below the newest entry clears the input
- **WHEN** the input shows the newest history entry and Down is pressed
- **THEN** the input is cleared and a further Up recalls the newest entry again

#### Scenario: Recall walks the list
- **WHEN** Up is pressed three times with five committed
  messages
- **THEN** the input holds the 3rd-most-recent message

#### Scenario: Discarded text not recorded
- **WHEN** the user types a line and clears it without Enter
- **THEN** it never appears in subsequent recall

### Requirement: Error banner
On an agent or API error the TUI SHALL show a one-line error banner
above the input. Enter or Esc on the banner SHALL clear it and
return the input to normal use immediately; neither key SHALL open a
modal view. The full error text SHALL go to the debug log when
`--debug` / `cfg.debug` is enabled and SHALL NOT be written to a
transcript row. While the banner is visible it does not own the
keyboard beyond Enter/Esc clearing it: a subsequent Enter (after the
banner is dismissed) SHALL submit normally.

An `aborted` turn is not an error: it SHALL append the dim
`⏹ прервано (Ctrl+C)` transcript row (ASCII `[x] прервано (Ctrl+C)`)
instead of raising the banner, and SHALL clear the waiting, streaming and
pending-retry indicators so no stale spinner or backoff stays on screen.

#### Scenario: Dismiss and send
- **WHEN** an error occurred, the user clears the banner with Enter
  or Esc, types a new message, and presses Enter
- **THEN** the new message is sent to the agent

#### Scenario: Enter clears the banner
- **WHEN** an error banner is showing and the user presses Enter
- **THEN** the banner is cleared and no overlay opens

#### Scenario: Esc clears the banner
- **WHEN** an error banner is showing and the user presses Esc
- **THEN** the banner is cleared and no overlay opens

#### Scenario: Full error text reaches the debug log
- **WHEN** `cfg.debug` is on and an `error` event arrives with full text
- **THEN** the debug log contains that text and the transcript gains no row carrying it

#### Scenario: Full error text never reaches the transcript
- **WHEN** an `error` event arrives
- **THEN** no transcript row is appended for the error message body

#### Scenario: Banner persists until next submit
- **WHEN** an error banner is showing and the user submits a new
  message without first clearing the banner
- **THEN** the banner clears as part of the submit (or Enter on the banner itself)

#### Scenario: An abort shows no banner
- **WHEN** a turn ends with an `aborted` event
- **THEN** the transcript gains the interrupted row and no error banner is set

#### Scenario: An abort clears the indicators
- **WHEN** a turn is aborted while it waited between attempts
- **THEN** no placeholder, caret, elapsed field or pending-retry field remains

### Requirement: Themes
The TUI SHALL support a set of named themes applied to roles, code, and
system lines; `ui.theme` selects the active one. The theme table SHALL
define at least the roles `accent`, `warn`, `error`, `success`, `dim`,
`italic`, `reverse`, `bold`, `comment`, `string`, `number`, `keyword`,
`code` and `heading`; `mono` SHALL leave every role missing (no SGR).
The `code` role SHALL colour inline code, and the `heading` role SHALL
colour markdown headings.

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

### Requirement: Reasoning streams as thinking rows

When the provider stream carries `reasoning_delta` events, the transcript SHALL render them as thinking rows: the deltas of one attempt SHALL accumulate into a single `thinking` entry whose body shows the joined reasoning under the live elapsed-time header, and its visibility SHALL follow `ui.thinking` — `collapsed` shows the `think ▸ (Ctrl+T)` placeholder instead of the body until Ctrl+T expands it. Reasoning text SHALL NOT appear as answer text: the assistant row carries only `text_delta` content. Thinking rows SHALL follow the block-gap and attempt-scoping rules like any other row, and SHALL NOT be sent to the agent or added to its history.

#### Scenario: Reasoning renders as one thinking row
- **WHEN** the stream emits three `reasoning_delta` chunks and then `text_delta` chunks
- **THEN** the transcript holds one thinking row with the joined reasoning under its `thinking · Ns` header, followed by the assistant row with the answer text only

#### Scenario: Collapsed thinking stays reachable
- **WHEN** `ui.thinking` is `collapsed` and reasoning streams
- **THEN** the transcript shows the `think ▸ (Ctrl+T)` placeholder instead of the reasoning body, and Ctrl+T expands the row

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

While the TUI waits between attempts the transcript carries the retry
row; the input box's top rule keeps showing the ordinary turn indicator
(a post-audit decision: the pending-retry top-rule leg is retired — the
retry explanation lives in the transcript row only, and the top rule
always shows the turn spinner while the turn is running).

These rows SHALL behave as transcript rows for scrolling and the
transcript height, SHALL NOT be sent to the agent, and SHALL NOT be
added to the agent history, and SHALL gain the block-gap blank row
before them (per the Turn separators gap rule). In ASCII mode they SHALL
use ASCII glyphs and SHALL NOT introduce a non-ASCII glyph.

#### Scenario: The failed attempt's rows are dropped
- **WHEN** an attempt streams `half an ans` and then fails retryably
- **THEN** that text is gone from the transcript and the retry row is the last row before the next attempt's output

#### Scenario: The successful attempt's rows are kept
- **WHEN** the attempt after a retry streams an answer
- **THEN** that answer stays in the transcript

#### Scenario: Retry row content
- **WHEN** the third attempt fails and the next wait is 8 seconds
- **THEN** one dim row names attempt 3, the 8-second wait and the failure reason

#### Scenario: Continuation row
- **WHEN** a truncated answer is continued
- **THEN** one dim row names the continuation

#### Scenario: Status line during the wait
- **WHEN** the TUI waits 60 seconds before the next attempt
- **THEN** the retry row names the 60-second wait and the input box's top rule keeps showing the ordinary turn indicator

#### Scenario: Painted without a keypress
- **WHEN** a retry or continuation event arrives
- **THEN** the row is painted while the turn is still running, without requiring a keypress

#### Scenario: Retry rows are not agent input
- **WHEN** the retry row is on screen and the turn continues
- **THEN** nothing from the row reaches the agent or its history

#### Scenario: ASCII mode
- **WHEN** ASCII mode is active during a retry
- **THEN** the retry row and the top-rule notice use ASCII glyphs and introduce no non-ASCII character

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

A blank row SHALL separate a separator row from the preceding transcript
entity, but a separator SHALL NOT add a blank row between itself and the
user row it labels. `ui.block_gap` (default 1; 0 = compact) SHALL control
the number of blank rows inserted between top-level entities (separator,
user, assistant, system); tool and thinking rows SHALL stay attached to
the preceding entity.

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

#### Scenario: Block gaps
- **WHEN** `ui.block_gap` is 1 and a user turn follows an assistant reply
- **THEN** one blank row separates the assistant block from the turn separator, and no blank row is added between the separator and its user row

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
and `json`, plus the common aliases `javascript`, `py`, `tsx`, `jsx`,
`shell`, `zsh`, `c++`, `cpp`, `cc`, `cxx`, `rs`, `yaml`, `yml`,
`golang`, `rb`. The language name in the fence SHALL match
case-insensitively, MAY carry trailing attributes (e.g. ```python
title=…), and SHALL stay visible in the frame. Coloring SHALL
distinguish at minimum comments, string literals, numbers and
language keywords, and SHALL take its colors from the active theme.
A supported language with no keyword set (`yaml`, `yml`, `rb`) SHALL
still highlight string literals and numbers, so the block is not
colourless.

The frame SHALL be rendered dim (box-drawing or ASCII) with the
language label readable in the default foreground; the frame SHALL
NOT itself be coloured.

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

### Requirement: Footer
The TUI SHALL render the footer as a single dim row below the input
box and SHALL NOT use a reverse-video row for it. The footer SHALL
occupy exactly one row regardless of active indicators.

That row SHALL carry, left to right, its blocks joined by a dim ` · `
separator: the workspace path with a leading `$HOME` abbreviated to
`~`; the session's accumulated input tokens as `↑<count>`, its
accumulated output tokens as `↓<count>` (each omitted while zero,
joined to each other by one space); the context cell
`used/max (pct%)`; any active transient flags joined by a single
space (the one-shot toast and the scroll indicator only — no
mouse-mode or keyboard-protocol icons); and the right-hand cell
`provider/model · <level>`, where `<level>` is the effective reasoning
level (`off`, `low`, `medium`, `high`) shown always (provider omitted
when unknown) right-aligned on
the same row, at least two columns away from the left side. No `≈`
or other estimate marker SHALL precede the context cell. Counts SHALL use the compact form: plain below
1000, one decimal with `k` below 10000, a rounded `k` below 1000000,
and `M` above. The right-hand cell SHALL end in the row's last column
whenever both sides fit; when they cannot both fit, the cell
SHALL be truncated from its left so its tail survives (the model name
loses its start first; the level label at the tail survives), and dropped
entirely only when nothing of it fits. When the left content alone
exceeds the available width, SHALL truncate in this order: path from
the right with a dim `...`, then transient flags dropped (toast
before the scroll indicator), then the left stats side from the
right with a dim `...`.

The footer's row SHALL be counted in display columns: wide
East-Asian characters count as 2 and ANSI sequences as 0. In ASCII
mode the token and scroll arrows SHALL render as `^` and `v`, and no
non-ASCII glyph SHALL be introduced by the footer.

#### Scenario: Idle footer
- **WHEN** no turn is running, no flag is active, and the session has used 3000 input and 1000 output tokens
- **THEN** the single footer row starts with the `~`-abbreviated workspace followed by `↑3.0k ↓1.0k` and the context cell, and ends with the right-hand cell `provider/model · <level>`

#### Scenario: Model is right-aligned
- **WHEN** the model name fits beside the left side
- **THEN** it ends in the last column of the footer row and at least two blank columns separate it from the left side

#### Scenario: Reasoning level follows the model

- **WHEN** the effective level is `medium` and the active provider is `agnes` with model `agnes-2.5-flash`
- **THEN** the right-hand cell reads `agnes/agnes-2.5-flash · medium` and still ends in the row's last column when it fits

#### Scenario: Level is shown even when off

- **WHEN** the effective level is `off`
- **THEN** the right-hand cell still ends with `· off`

#### Scenario: Counters accumulate across turns
- **WHEN** one turn reports 1200 prompt and 300 completion tokens and a later turn reports 800 and 200
- **THEN** the counters read `↑2.0k` and `↓500`

#### Scenario: Context cell keeps its thresholds
- **WHEN** token usage reaches `ui.summarize_at`
- **THEN** the context cell is rendered as a warning, and at 90% or more as an error

#### Scenario: Toast and scroll share the footer row
- **WHEN** a one-shot toast is active and the transcript is scrolled up
- **THEN** the footer's single row carries both the toast and `↓ +N` separated by one space (no second or third footer row is painted), and each disappears when it expires or returns to the bottom

#### Scenario: No reverse video
- **WHEN** the footer row is rendered
- **THEN** no footer row uses reverse video and the row is dim

#### Scenario: Narrow terminal drops the model name
- **WHEN** the model name cannot fit beside the left side of the footer
- **THEN** the left side is rendered intact and the right-hand cell is truncated from its left — the model name loses its start first while the ` · <level>` tail survives, and the cell is omitted only if nothing of it fits

#### Scenario: ASCII mode
- **WHEN** ASCII mode is active and counters are shown
- **THEN** the arrows render as `^` and `v` and the footer introduces no non-ASCII glyph

### Requirement: Question block

When the agent emits an `ask` event the TUI SHALL render a question block at the
tail of the transcript, built like the confirmation menu so it scrolls, counts
toward the transcript height, and is removed when it is resolved.

The block SHALL show:

- a `?` row with the question text, carrying an `N/M` progress indicator when the
  call holds more than one question;
- the question's `description`, when present, as read-only markdown-lite context
  above the options;
- one row per option, each prefixed with its 1-based index, the highlighted row
  rendered like the confirmation menu's selected row;
- the model's `recommended` option marked as the suggestion;
- on a `multi` question a toggled/un-toggled marker on every option row;
- a note already written on an option as a dim line beneath that option;
- a final freeform row, always present, inviting the user to type their own
  answer.

While the block is open the TUI SHALL clear the waiting placeholder, the caret
and the elapsed field, exactly as it does when a confirmation menu is raised —
the turn is waiting on the user. No header or hint row SHALL be added beyond the
rows above.

#### Scenario: Single question
- **WHEN** a single-question `ask` event arrives
- **THEN** the block shows the question text, its options with indices, and the freeform row, with no progress indicator

#### Scenario: Several questions
- **WHEN** a three-question `ask` event arrives
- **THEN** the first question is shown with a `1/3` indicator

#### Scenario: Description context
- **WHEN** the question carries a description
- **THEN** it is rendered above the options as formatted read-only context

#### Scenario: Recommended option
- **WHEN** the question marks option 2 as recommended
- **THEN** that row is marked as the suggestion while the highlight stays on the first option

#### Scenario: Waiting state cleared
- **WHEN** the block appears during a turn
- **THEN** no placeholder, caret or elapsed field is painted while it is open

#### Scenario: ASCII mode
- **WHEN** ASCII mode is active
- **THEN** every glyph the block introduces (toggles, note marker, progress) is rendered with an ASCII equivalent

### Requirement: Answering a question by keyboard

While the block is open it SHALL own the keyboard: a key the block does not use
SHALL NOT reach the input line, the palette or the transcript scroll.

- `↑`/`↓` SHALL move the highlight across the option rows and the freeform row.
- On a single-answer question, `Enter` SHALL submit the highlighted option and a
  digit `1..9` SHALL submit the option with that index.
- On a `multi` question, `Space` and a digit `1..9` SHALL toggle the option with
  that index without submitting, and `Enter` SHALL accept the current selection
  and move on.
- `Enter` on the freeform row SHALL open the freeform editor when the question
  has no committed freeform text, and SHALL submit the question (single answer)
  or accept the current selection and move on (`multi`) once text is committed,
  so a freeform-only answer can be sent.
- `Tab` on an option row SHALL open that option's note editor.
- `←` SHALL return to the previous question of the same call when one has already
  been answered, restoring its selections, freeform answer and notes for editing.
- `Esc` SHALL cancel the question set (see "Submitting and cancelling a question
  set").

#### Scenario: Pick with the arrow and Enter
- **WHEN** the user presses `↓` on a single-answer question and presses `Enter`
- **THEN** the second option is the answer and the question is submitted

#### Scenario: Pick with a digit
- **WHEN** the user presses `3` on a single-answer question with at least three options
- **THEN** the third option is submitted

#### Scenario: Multi-select
- **WHEN** the user presses `Space` twice on a `multi` question
- **THEN** two options are marked selected and nothing is submitted yet

#### Scenario: A freeform-only answer can be submitted
- **WHEN** the user opens the freeform row, commits `Nuxt`, and presses `Enter` again
- **THEN** the question is answered with that text and the set moves on

#### Scenario: Freeform row without text
- **WHEN** the user presses `Enter` on the freeform row with no committed freeform text
- **THEN** the freeform editor opens instead of submitting

#### Scenario: Return to a previous question
- **WHEN** the user has answered the first of two questions and presses `←` on the second
- **THEN** the first question is shown again with its answer still selected

#### Scenario: Unused keys do not leak
- **WHEN** the user types an ordinary letter while the block is open
- **THEN** the input line is unchanged and nothing is submitted

### Requirement: Freeform answer and option notes

Choosing the freeform row SHALL open a single-line editor inside the block,
prefilled with the current freeform answer; `Tab` on an option SHALL open a
single-line note editor for that option, prefilled with that option's saved note.
While an editor is open, characters and backspace SHALL edit its text
(the question highlight SHALL NOT move), `Enter` SHALL commit the text — an empty
commit clearing the value — and return to the option list, and `Esc` SHALL
discard the edits made in that editor and return to the option list without
cancelling the question set.

#### Scenario: Freeform text becomes the answer
- **WHEN** the user opens the freeform row, types `Nuxt` and presses `Enter`
- **THEN** the question is answerable with that text and the option list is shown again

#### Scenario: Note is written on an option
- **WHEN** the user presses `Tab` on an option, types a note and presses `Enter`
- **THEN** the note is shown beneath that option and travels with the answer

#### Scenario: Note discarded
- **WHEN** the user opens a note editor, types text and presses `Esc`
- **THEN** no note is recorded and the question set is still open

#### Scenario: Editing keys do not move the highlight
- **WHEN** the user presses `↑` while a note editor is open
- **THEN** the question's highlight is unchanged

### Requirement: Submitting and cancelling a question set

On the last question, `Enter` SHALL submit the whole answer set. Submitting SHALL
remove the block, append one dim row summarising the answers (the question ids
with their selected labels, freeform text and notes), and resume the turn.

`Esc` in the option list SHALL cancel the whole set: the block is removed, one
dim row records the cancellation, the tool result reports it without an error
banner, and the turn continues.

#### Scenario: Submitted answer is recorded
- **WHEN** the user submits answers to two questions
- **THEN** the block is gone, one dim row summarises both answers, and the turn resumes

#### Scenario: Cancel
- **WHEN** the user presses `Esc` in the option list
- **THEN** the block is gone, a dim row records the cancellation, and the turn continues without an error banner

### Requirement: Session lists are palette modes

`/resume` SHALL open the shared palette with `palette_mode = "resume"` and items from the session listing (never a full-screen overlay). Enter SHALL resume the selected session, replace the visible transcript via transcript seed, and append a resumed-session marker; Esc SHALL close the palette with no side effects; arrows and mouse selection SHALL behave as for `/copy`. `/model` SHALL open the shared palette with `palette_mode = "model"` and items from the model listing; Enter SHALL set `S.model_name` (and `S.cfg.model`), persist the pick into `~/.tether/config.lua` per the config model-persistence requirement, and append a `→ модель: …` system row; Esc SHALL close without changing the model. Neither mode SHALL set `S.overlay`.

#### Scenario: Resume opens a palette
- **WHEN** the user runs `/resume` with at least one session on disk
- **THEN** `palette_mode` is `resume`, the palette is active, items are non-empty, and no overlay is open

#### Scenario: Resume Enter picks a session
- **WHEN** the resume palette is open and the user presses Enter on a session
- **THEN** the palette closes, `S.session_id` updates, and the transcript is replaced with the picked session plus a marker

#### Scenario: Resume Esc is a no-op
- **WHEN** the resume palette is open and the user presses Esc
- **THEN** the palette closes and no session is resumed

#### Scenario: Model opens a palette
- **WHEN** the user runs `/model`
- **THEN** `palette_mode` is `model`, the palette is active with model items, and no overlay is open

#### Scenario: Model Enter changes the model
- **WHEN** the model palette is open and the user presses Enter on a model
- **THEN** `S.model_name` is that model, a system row `→ модель: …` is appended, and `~/.tether/config.lua` holds the picked `provider`/`model` afterwards

#### Scenario: Model Esc does not change the model
- **WHEN** the model palette is open and the user presses Esc
- **THEN** `S.model_name` is unchanged and the palette closes

### Requirement: Login secret mode
Bare `/login` SHALL open the provider picker as
`palette_mode = "login"` (shared palette, never an overlay). Selecting a
provider SHALL enter secret mode: `S.login_secret = { buf = "" }` (a
dedicated buffer, never `S.input`), `S.overlay` SHALL stay unset, and the
provider picker SHALL close. While secret mode is open it owns the
keyboard: text/paste append to `buf`, backspace edits `buf`, Enter runs
`submit_login_secret(buf)` (store per auth rules, then clear secret mode),
Esc runs `cancel_login()` (clear secret mode, store nothing).
`render_input` SHALL paint a masked line `login <provider>: *…` (length
only); the plaintext secret SHALL NOT appear in the painted frame, in
`S.input`, or in any transcript row. OAuth failure that re-opens secret
mode SHALL NOT set an overlay.

#### Scenario: Picker Enter enters secret mode
- **WHEN** the user opens bare `/login`, selects a provider, and presses Enter
- **THEN** `S.login_secret` is non-nil, the palette is closed, and `S.overlay` is unset

#### Scenario: Secret never enters main input
- **WHEN** the user pastes a key while secret mode is open
- **THEN** `S.login_secret.buf` holds the text and `S.input` is unchanged

#### Scenario: Frame masks the secret
- **WHEN** secret mode has buffered text and a frame is painted
- **THEN** the frame contains mask characters and does not contain the plaintext

#### Scenario: Esc cancels without store
- **WHEN** secret mode is open and the user presses Esc
- **THEN** `S.login_secret` is cleared, nothing is stored, and no overlay is open

#### Scenario: Enter stores and clears
- **WHEN** secret mode has a non-empty `buf` and the user presses Enter
- **THEN** the credential is stored per auth rules, secret mode is cleared, and no overlay is open

### Requirement: Login picker lists full catalog

The bare-`/login` provider picker SHALL list every provider-catalog id (not a hardcoded triple), derived from the same catalog the dispatcher uses, so picker and dispatcher can never disagree.

#### Scenario: New preset appears in picker
- **WHEN** the catalog contains `deepseek`
- **THEN** bare `/login` lists `deepseek` and selecting it enters secret mode for `deepseek`
