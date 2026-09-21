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
appears twice.
Filtering SHALL be a case-insensitive subsequence match over the row
name (the command name, or `/<skill-name>`): prefix matches SHALL rank
above interior matches, ties SHALL keep the candidate order, and an
empty filter SHALL list every candidate in that order. Selection SHALL
use arrows; Enter SHALL run the highlighted command, and for a skill
SHALL replace the input with `/<name> ` (trailing space, cursor at the
end) and close the palette. Tab SHALL complete the selected row into
the input as `/<name> ` whether it is a command or a skill. Esc SHALL
close the palette leaving the typed text. Enter SHALL apply the
highlighted row only when the palette holds a match; with no match the
palette SHALL render no rows and Enter SHALL neither run a command nor
submit the input. The palette SHALL close when the filter contains a
space or the first character is no longer `/`.

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
- **THEN** the palette shows no rows, no command runs, and no message is submitted

#### Scenario: Space closes the palette
- **WHEN** the user types `/model ` (with a trailing space)
- **THEN** the palette closes and the text stays in the input

### Requirement: Skills in the palette
Skills discovered by the context-injection discovery rules SHALL be
rows of the slash palette (see `Palette`) rather than a separate list;
there SHALL be no dedicated skills command and no second palette mode.
Selecting a skill SHALL replace the input with `/<name> ` naming that
skill, leaving the cursor at the end, so the user appends the task and
sends it; the skill body SHALL NOT be read into the input and SHALL NOT
appear in the transcript, and the `SKILL.md` path SHALL NOT be inserted.
A submitted message that starts with `/` and with a name that is not a
command SHALL be sent to the agent as an ordinary user message, exactly
once, instead of being cleared. With no skill discovered the palette
SHALL list only the commands, without a placeholder row. Discovery
problems SHALL NOT break the palette or the session: they SHALL degrade
to no skill rows.

#### Scenario: Discovered skills are listed
- **WHEN** two skills are discovered and the user types `/`
- **THEN** both are listed after the commands, in discovery order, as `/<name>` with their descriptions

#### Scenario: Selecting a skill only references it
- **WHEN** the user selects skill `deploy` whose file is `~/.tether/skills/deploy/SKILL.md`
- **THEN** the input becomes `/deploy ` with the cursor at the end, the palette closes, and neither the body of `SKILL.md` nor its path appears in the input

#### Scenario: Submitted skill reference reaches the agent
- **WHEN** the input is `/deploy ship the app` and the user presses Enter with the palette closed
- **THEN** `agent.turn` runs once with that text as the user message, and nothing is cleared as an unknown command

#### Scenario: No skills
- **WHEN** no skill is discovered and the user types `/`
- **THEN** the palette lists only the commands and no placeholder row is shown

#### Scenario: Skills follow the -w workspace
- **WHEN** tether runs in another directory with `-w /ws` and `/ws/.agents/skills/deploy/SKILL.md` exists
- **THEN** `/deploy` is listed in the palette, because discovery reads the workspace from the effective config rather than the process cwd

#### Scenario: Modules come from the embedded globals
- **WHEN** the palette runs in the built binary, which exposes each Lua module as a global and defines no `package.preload`
- **THEN** skill discovery reaches the `context` module and Tab path completion reaches the `tools` module through those globals, without relying on `require`
