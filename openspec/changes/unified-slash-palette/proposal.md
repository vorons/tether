# Proposal

## Why

The `/` palette lists only the eight built-in commands, while project skills
live behind a separate `/skills` palette that inserts a `[skill: …]`
reference nothing in the agent actually parses. Skills are therefore
invisible exactly where the user looks for them, and the palette cannot
handle a long list at all: `render_palette` paints the first rows of the
list regardless of the selection, so with more entries than rows the
highlighted row can leave the screen entirely.

The reference implementation (pi) shows the model we want: one slash list
whose entries carry an optional argument hint, rendered through a scrolling
window that keeps the selection visible.

## What Changes

- The `/` palette becomes the single slash surface: the built-in commands
  first (declared order), then the skills discovered by the
  context-injection discovery rules, each rendered as `/<name>`.
- One filter and one ranking run over the combined list, so a skill is found
  by typing its own name; ties keep the list order, which keeps commands
  ahead of skills.
- Selecting a skill (Enter or Tab) only completes `/<name> ` into the input.
  No body is read, nothing is executed, nothing reaches the transcript.
- **BREAKING**: `/skills` and its palette are removed, and the `[skill: …]`
  reference is no longer produced. Skills are reached through the unified
  palette instead.
- A skill whose name collides with a built-in command, case-insensitively, is
  not listed: the command wins, and the skill stays reachable by asking the
  agent for it, since the skills index in the system prompt still names it.
- Submitting `/<name>` that matches a discovered skill is sent to the agent
  as an ordinary message. Without this the name would be swallowed:
  `commit_input` routes any `/<word>` to `execute_command`, and that
  function clears the input and does nothing for a command it does not know.
- Slash names are resolved without regard to case, on the command lookup and
  on the skill lookup alike, so `/Deploy` reaches skill `deploy` and `/CLEAR`
  runs `/clear`, matching the case-insensitive palette filter.
- The palette scrolls: it renders a window of at most 8 rows, and no more
  than half the terminal height, shifted so the selected row is always
  visible. When the list is longer than the window a dim `sel/total`
  indicator row (ASCII-safe, digits and `/` only) appears inside the space
  the footer budget already reserves.
- Every palette row may carry an argument hint (`[…]`/`<…>`), shown next to
  the name. Today only skill rows declare one (`[задача]`); the built-in
  commands declare none because they take no arguments, and a hint must not
  promise behavior the command does not have.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `tui`: the slash-command palette requirement is rewritten (unified
  command + skill list, scrolling window, argument hints, skill selection
  that only completes the input), the `Skills in the palette` requirement
  is removed, and a requirement for submitting a skill by name is added.

## Impact

- `src/tether/ui.lua`: the command table, `palette_sync`, `render_palette`,
  `layout`, `execute_command`, `commit_input`, and the `palette_mode ==
  "skills"` branches in key and mouse handling.
- `src/tether/context.lua`: `discover_skills` becomes the source of palette
  skill rows; its API is unchanged.
- `tests/lua_tests.lua`: the palette and skills-palette tests are rewritten,
  and window, hint, and submit-by-name behavior gain coverage.
- `README.md`, `docs/design.md`, `docs/tech-spec.md`: the palette section,
  the `/skills` documentation, and the key/behavior tables.
- Users: `/skills` disappears; muscle memory for it moves to `/` plus the
  skill name.
