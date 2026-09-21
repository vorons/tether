# Spec Delta

## ADDED Requirements

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

## MODIFIED Requirements

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

## REMOVED Requirements

### Requirement: Skills in the palette
**Reason**: Skills are now entries of the single slash palette, so a second
palette with different selection semantics (a `[skill: …]` reference instead
of the name) duplicated the entry point and offered a second, inconsistent
result for the same user intent.

**Migration**: Type `/` and the skill's name (`/deploy`); the name is listed
together with the commands. Enter completes `/<name> ` into the input, and
submitting it sends the name to the agent as an ordinary message. The
`[skill: …]` reference is no longer produced, and with no skill discovered the
palette shows the commands only — the former `(нет скиллов)` empty row is
gone.
