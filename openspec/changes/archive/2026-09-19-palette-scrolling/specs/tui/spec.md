# Spec Delta: tui

## MODIFIED Requirements

### Requirement: Palette
Typing `/` as the first non-blank character of the first input line
SHALL open a command palette listing the available slash commands
(`/clear /compact /model /resume /new /quit /copy`) and every skill
discovered by the context-injection discovery rules, each skill
rendered as `/<name>` with its description. Candidate order SHALL be
the declared command order followed by skills in discovery order; a
skill whose `/<name>` equals a command name SHALL be omitted so no row
appears twice. Filtering SHALL be a case-insensitive subsequence match
over the row name (the command name, or `/<skill-name>`): prefix
matches SHALL rank above interior matches, ties SHALL keep the
candidate order, and an empty filter SHALL list every candidate in that
order. Selection SHALL use arrows; Enter SHALL run the highlighted
command, and for a skill SHALL replace the input with `/<name> `
(trailing space, cursor at the end) and close the palette. Tab SHALL
complete the selected row into the input as `/<name> ` whether it is a
command or a skill. Esc SHALL close the palette leaving the typed text.
The palette SHALL draw at most 8 candidate rows and never more than
half of the terminal height, choosing a window that keeps the selected
candidate visible: the selection SHALL sit centred in the window while
there is room on both sides and the window SHALL be clamped to the
first and last candidates otherwise. While any candidate is hidden the
palette SHALL render an `(n/total)` indicator, where n is the position
of the selected candidate. With no match the palette SHALL render a
single `нет совпадений` row, hold no selectable candidates, and Enter
SHALL neither run a command nor submit the input. The palette SHALL
close when the filter contains a space or the first character is no
longer `/`.

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
- **THEN** every command is listed in declared order with its description, followed by every discovered skill as `/<name>` with its description

#### Scenario: Skill ranks with the commands
- **WHEN** a skill named `model-review` is discovered and the user types `/model`
- **THEN** both `/model` and `/model-review` are listed, with `/model` first because an equal rank keeps the candidate order

#### Scenario: Skill name collides with a command
- **WHEN** a skill named `copy` is discovered and the user types `/`
- **THEN** `/copy` is listed once and Enter runs the copy command

#### Scenario: No match
- **WHEN** the user types `/zzz` and presses Enter
- **THEN** the palette shows only the `нет совпадений` row, no command runs, and no message is submitted

#### Scenario: Space closes the palette
- **WHEN** the user types `/model ` (with a trailing space)
- **THEN** the palette closes and the text stays in the input

#### Scenario: The window follows the selection
- **WHEN** more candidates match than the palette can draw and the user presses `↓` past the last drawn row
- **THEN** the palette redraws so the selected candidate is visible, keeping it centred while there is room

#### Scenario: Indicator shows the position
- **WHEN** the palette holds more candidates than it draws and the selection is the eighth of twelve
- **THEN** the palette renders `(8/12)` in the row that follows the drawn candidates

#### Scenario: No indicator when everything fits
- **WHEN** the palette holds fewer candidates than it draws
- **THEN** no `(n/total)` indicator is rendered

#### Scenario: Height is capped by the terminal
- **WHEN** the terminal is 12 rows high
- **THEN** the palette draws at most 6 candidate rows and the input block and status line stay on screen
