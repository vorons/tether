# Proposal: skills-in-main-palette

## Why

Skills are reachable only through a dedicated `/skills` palette that is
disconnected from the slash menu: the main palette is built exclusively from
the static `SLASH_COMMANDS` table (`ui.lua:1109-1113`), so a discovered skill
never shows up while typing `/`. Users expect one list — type `/`, see the
commands **and** the skills.

Two consequences fall out of the separate list:

- Skills are invisible until the user knows `/skills` exists, and the skill
  name is never part of what the palette filters over.
- Selecting a skill appends a `[skill: name — SKILL.md at path]` reference to
  the input, but a skill typed by hand as `/deploy …` is swallowed:
  `commit_input` dispatches any `^/(%w+)` to `execute_command`, which clears the
  input and does nothing for an unknown name (`ui.lua:2590-2598`,
  `ui.lua:2312-2314`). Such text never reaches the agent.

## What Changes

- **Skills become rows of the main palette.** Typing `/` lists the commands and
  every discovered skill, the skill rendered as `/<name>` with its description.
  Both kinds share one filter and one ranking (prefix beats interior match,
  ties keep candidate order: commands first, then skills in discovery order).
- **Enter on a skill substitutes its reference into the input.** The palette
  closes and the input becomes `/name ` (trailing space, cursor at the end), so
  the user appends the task and sends it as one message.
- **A submitted `/name <task>` reaches the agent.** Command dispatch runs only
  for a name that is actually a command; anything else is sent as a normal user
  message instead of being cleared silently.
- **The separate skills palette is removed.** The `/skills` command, the
  `palette_mode == "skills"` branch and the `_in_skills_palette` flag all go; an
  empty discovery adds no rows (no `(нет скиллов)` placeholder) and never breaks
  the palette or the session.
- **Discovery is cached per session.** The palette re-syncs on every keystroke,
  so the skill list is resolved once (lazily, on the first `/`) and reused; it is
  refreshed when a new session starts.

## Capabilities

### New Capabilities
- None.

### Modified Capabilities
- `tui`: the palette requirement lists skills alongside commands, and the
  skills requirement describes rows in that palette rather than a separate one.

## Impact

- Code: `src/tether/ui.lua` (`SLASH_COMMANDS`, `palette_sync`, the palette key
  branch, `execute_command`, `commit_input`); `context.discover_skills` is reused
  unchanged, still behind the `M._skills_stub` test seam.
- Tests: `tests/lua_tests.lua` — T79–T81 are rewritten against the merged
  palette, plus new coverage for the `/name ` substitution and for a submitted
  skill reference reaching the agent once.
- Docs: `README.md` and `docs/design.md` lose the `/skills` palette description;
  `openspec/specs/tui/spec.md` is updated by this change's delta.
- No config, wire-format or C host change; sessions and the agent loop are
  untouched.
