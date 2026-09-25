# Spec Delta

## ADDED Requirements

### Requirement: Reasoning streams as thinking rows

When the provider stream carries `reasoning_delta` events, the transcript SHALL render them as thinking rows: the deltas of one attempt SHALL accumulate into a single `thinking` entry whose body shows the joined reasoning under the live elapsed-time header, and its visibility SHALL follow `ui.thinking` — `collapsed` shows the `think ▸ (Ctrl+T)` placeholder instead of the body until Ctrl+T expands it. Reasoning text SHALL NOT appear as answer text: the assistant row carries only `text_delta` content. Thinking rows SHALL follow the block-gap and attempt-scoping rules like any other row, and SHALL NOT be sent to the agent or added to its history.

#### Scenario: Reasoning renders as one thinking row

- **WHEN** the stream emits three `reasoning_delta` chunks and then `text_delta` chunks
- **THEN** the transcript holds one thinking row with the joined reasoning under its `thinking · Ns` header, followed by the assistant row with the answer text only

#### Scenario: Collapsed thinking stays reachable

- **WHEN** `ui.thinking` is `collapsed` and reasoning streams
- **THEN** the transcript shows the `think ▸ (Ctrl+T)` placeholder instead of the reasoning body, and Ctrl+T expands the row

## MODIFIED Requirements

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
