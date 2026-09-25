# Spec Delta

## MODIFIED Requirements

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

### Requirement: Turn separators

The TUI SHALL insert one dim separator row before each new user turn in the
transcript, carrying the local wall-clock submission time as `── HH:MM ──`
(ASCII `-- HH:MM --`). Separator rows SHALL behave as transcript rows for
scrolling and the transcript height, and SHALL NOT be sent to the agent or
added to the agent history. They SHALL be controlled by `ui.turn_separators`
(default on); with it off no separator rows are created. The TUI SHALL NOT
synthesize separators for the messages restored by `-r` startup or `/resume`,
because no submission time is available for them. `/clear` SHALL drop
separators together with the rest of the transcript and `/new` SHALL drop them
with the previous session.

A blank row SHALL separate a separator row from the preceding transcript
entity, but a separator SHALL NOT add a blank row between itself and the user
row it labels. `ui.block_gap` (default 1; 0 = compact) SHALL control the number
of blank rows inserted between top-level entities (separator, user, assistant,
system); tool and thinking rows SHALL stay attached to the preceding entity.

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

### Requirement: Retry and continuation notices

While a turn is being retried or continued the TUI SHALL keep the user informed
with dim system rows, painted as the events arrive and without waiting for a
keypress.

On a `retry` event the TUI SHALL first remove every transcript row painted for
the attempt that just failed — the assistant-text and reasoning rows that
attempt produced — and then append one dim row naming the failed attempt
number, the wait in seconds, and the failure reason. Rows produced by an
earlier attempt SHALL NOT be kept, and rows produced by the attempt that
follows SHALL NOT be removed.

On a `continuation` event the TUI SHALL append one dim row naming what was
continued, so an answer that was stitched together is visibly stitched.

While the TUI waits between attempts the transcript carries the retry row; the
input box's top rule keeps showing the ordinary turn indicator (a post-audit
decision: the pending-retry top-rule leg is retired — the retry explanation
lives in the transcript row only, and the top rule always shows the turn
spinner while the turn is running).

These rows SHALL behave as transcript rows for scrolling and the transcript
height, SHALL NOT be sent to the agent, and SHALL NOT be added to the agent
history, and SHALL gain the block-gap blank row before them (per the Turn
separators gap rule). In ASCII mode they SHALL use ASCII glyphs and SHALL NOT
introduce a non-ASCII glyph.

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

### Requirement: Code block syntax highlighting

Fenced code blocks SHALL be rendered with per-language token coloring when the
fence info string names a supported language: `lua`, `c` (and `h`), `sh` (and
`bash`), `python`, `js` (and `ts`), `go`, `rust` and `json`, plus the common
aliases `javascript`, `py`, `tsx`, `jsx`, `shell`, `zsh`, `c++`, `cpp`, `cc`,
`cxx`, `rs`, `yaml`, `yml`, `golang`, `rb`. The language name in the fence
SHALL match case-insensitively, MAY carry trailing attributes
(e.g. ` ```python title=… `), and SHALL stay visible in the frame. Coloring
SHALL distinguish at minimum comments, string literals, numbers and language
keywords, and SHALL take its colors from the active theme. A supported
language with no keyword set (`yaml`, `yml`, `rb`) SHALL still highlight
string literals and numbers, so the block is not colourless.

The frame SHALL be rendered dim (box-drawing or ASCII) with the language label
readable in the default foreground; the frame SHALL NOT itself be coloured.

Highlighting SHALL NOT change the block's text or geometry: removing ANSI
sequences from the highlighted rows SHALL reproduce the unhighlighted
rendering exactly, and each row's display width SHALL be identical in both
renderings. An unsupported, absent or non-alphabetic fence info string SHALL
render highlighted-free (as today).

`ui.highlight` SHALL control the feature: `"off"` disables token coloring,
`"on"` enables it whenever color is available, and `"auto"` (default) enables
it when the terminal is color-capable. ASCII mode, `ui.ascii` forced on, and
`NO_COLOR=1` SHALL suppress token coloring regardless of `ui.highlight`,
leaving pure-ASCII output.

Color depth SHALL be negotiated once at startup and SHALL degrade: 24-bit SGR
when `COLORTERM` advertises `truecolor` or `24bit`, otherwise 256-color SGR,
otherwise the 16-color palette. Rendering SHALL stay legible at every depth.

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

### Requirement: Palette

Typing `/` as the first non-blank character of the first input line SHALL open
a command palette listing the available slash entries: the built-in commands
(`/clear /compact /model /resume /new /quit /copy`) in declared order,
followed by the skills discovered by the context-injection discovery rules,
each rendered as `/<name>` in discovery order. A skill whose name matches a
built-in command name without regard to case SHALL NOT be listed: the command
owns that token, and case SHALL NOT decide which of the two it is.

Each row SHALL render the entry name, its short description, and, after the
name, the entry's argument hint when it has one. A skill row SHALL show the
hint `[skill]`; an entry that takes no arguments SHALL NOT show a hint. The
name column SHALL be padded to the widest name+hint across all listed entries
so command and skill descriptions align in the same column.

Filtering SHALL be a case-insensitive subsequence match over the entry name
(the command name or the skill name): prefix matches SHALL rank above interior
matches, ties SHALL keep the list order (commands before skills, and within
each group the declared or discovery order), and an empty filter SHALL list
every entry in that order.

Selection SHALL move with the arrows. Enter on a command row SHALL run that
command; Enter on a skill row SHALL only write `/<name> ` into the input and
close the palette, sending nothing, and the skill body SHALL NOT be read into
the input and SHALL NOT appear in the transcript. Tab SHALL write the selected
entry's `/<name> ` into the input, and Esc SHALL close the palette leaving the
typed text. Enter SHALL act on the highlighted entry only when the palette
holds a match; with no match the palette SHALL render no rows and Enter SHALL
neither run a command nor submit the input.

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

### Requirement: Themes

The TUI SHALL support a set of named themes applied to roles, code, and system
lines; `ui.theme` selects the active one. The theme table SHALL define at least
the roles `accent`, `warn`, `error`, `success`, `dim`, `italic`, `reverse`,
`bold`, `comment`, `string`, `number`, `keyword`, `code` and `heading`;
`mono` SHALL leave every role missing (no SGR). The `code` role SHALL colour
inline code, and the `heading` role SHALL colour markdown headings.

#### Scenario: Theme switch

- **WHEN** the user changes `ui.theme` in config and restarts
- **THEN** the new theme is applied to the next render
