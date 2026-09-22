# Design

## Context

See `proposal.md` — Why. The current state that shapes the approach:

- `palette_sync` derives `S.palette_items` from the static `SLASH_COMMANDS`
  table every time the input changes, and bails out early while another
  palette owns the region (`S._in_copy_palette`, `S._in_skills_palette`).
- `layout` reserves `palette_h = min(#items, 8) + 2` rows for the palette;
  `render_palette` paints `min(#items, palette_h - 2)` rows starting at
  index 1. The painted rows never follow the selection, and the reserved
  region holds one row more than is painted.
- Key handling branches on `palette_mode` (`command`, `skills`, `copy`,
  `path`); mouse presses map a screen row to `palette_items[row -
  palette_row]` with no window offset.
- `commit_input` routes any `^/(%w+)` token to `execute_command`, which
  clears the input first and, for a name it does not know, does nothing.
- Skills come from `context.discover_skills` (config `skills_dirs`, first-wins
  by name), and the composed system prompt already carries a skills index
  with each skill's name, description and file path.

## Goals / Non-Goals

**Goals:**

- One slash surface where every entry — command or skill — is filtered and
  selected by the same rules.
- A palette that stays usable when the entry list is longer than the rows
  available, with the selection always visible.
- Skill selection that only composes text into the input and never reads a
  skill body.

**Non-Goals:**

- Argument parsing for commands; hints are display-only.
- New config keys: the window derives from the terminal height and a fixed
  cap.
- Reworking the ranking function, the copy/model/resume overlays, the path
  completion palette, or skill discovery rules.
- Keeping `/skills` as an alias for the new entries.

## Decisions

### 1. One entry list, built by one builder

`palette_sync` will build `S.palette_items` from a single list: the built-in
commands in declared order, then the skill rows in discovery order, and rank
that list with the existing `fuzzy_rank`. Ranking skills as a separate group
and concatenating the results was rejected: finding `/dep` must beat nothing
else, but a prefix match in either group has to outrank an interior match in
the other, which only a single ranking can express.

### 2. Skill rows resolve once per palette open

Discovery reads directories and `SKILL.md` files, so it must not run per
keystroke. Skills will be resolved into `S.palette_skills` when the palette
transitions from closed to open and reused while it stays open; a failure
yields `{}` so the palette degrades to commands only. `M._skills_stub` stays
as the test seam, which also keeps palette tests independent of the
developer's `~/.tether/skills`.

### 3. A skill colliding with a command is not listed

Collision is decided without regard to case, so the command owns the token,
the palette lists only the command row, and the submit path never reaches the
skill. Re-listing the skill as `/skill:<name>` was rejected: it reintroduces
exactly the prefix the unified list removes, and the agent can still use the
skill from the skills index in its prompt.

### 4. Skill selection composes text; submitting it sends a message

Enter or Tab on a skill row sets the input to `/<name> ` with the cursor at
the end and closes the palette. Nothing is executed and no body is read:
the agent sees the name plus whatever the user typed after it, and the skills
index tells it which file to read.

`commit_input` therefore needs one new branch. `/<word>` keeps its current
meaning when `word` names a command; when it names a discovered skill the
text is submitted as an ordinary user message; otherwise the existing command
path is untouched. Sending every unknown `/word` as a message instead was
rejected because it would turn command typos into prompts and widen this
change well past the palette.

Comparison ignores case on both lookups. Folding only the skill lookup was
rejected: with a skill named `copy` hidden behind the command, `/COPY` would
match neither an exactly-compared command nor the hidden skill and would do
nothing at all, which is worse than either consistent rule. Ignoring case for
commands costs nothing in practice — the palette already filters
case-insensitively, so `/CLEAR` already shows and runs `/clear` when picked;
the change only makes a hand-typed `/CLEAR` agree with that instead of being
silently dropped.

The name is re-resolved at submit time, so a name that stopped resolving
between opening the palette and submitting falls back to the existing path.

### 5. A window that follows the selection, plus an overflow indicator

The rendered window is `min(#items, 8, max(1, floor(h / 2)))` rows. A window
offset shifts so the selected row is inside, and `render_palette` paints
`items[offset + i]`. Because the reserved palette region already holds one
row more than is painted, the `sel/total` indicator (digits and `/` only, no
symbol glyph) takes that spare row, and `layout` keeps its current formula
shape with the window in place of the fixed cap — so the footer budget
requirement is untouched.

The spare row exists only while the layout is not clamped: `layout` computes
`th = S.h - fixed` and clamps it to at least 1, so on a terminal too short for
the footer the regions shift and can already overlap (pre-existing, out of
scope here). The indicator is therefore painted only when
`palette_row + window + 1 <= separator_row - 1`; otherwise it is omitted and
the entry rows keep their window, so this change adds no new overlap.

Click mapping moves with it: a press inside the painted window resolves to
`offset + (row - palette_row)`, and a press on the indicator row does
nothing. Without that, clicking would select the wrong entry for any list
longer than the window.

### 6. Hints are optional per-entry data

Each entry carries an optional `hint`; skill rows declare `[задача]` and
command rows declare none. Inventing hints for the built-in commands was
rejected: none of them parses arguments, so a hint would document behavior
that does not exist. When a command gains real arguments, it declares the
hint in the same place.

## Risks / Trade-offs

- [Dropping `/skills` breaks muscle memory and a documented feature] →
  recorded as BREAKING in the proposal; `README.md`, `docs/design.md` and
  `docs/tech-spec.md` are updated in the same change, and the palette finds
  skills by name.
- [Palette tests assert an exact eight-item list and would become sensitive
  to a developer's skill directories] → every palette test stubs discovery
  (`M._skills_stub`) so the entry count is deterministic.
- [Skill rows can be numerous, and the window hides most of them] → the
  selection always stays visible and the indicator reports the position;
  filtering by name remains the primary way to reach a skill.
- [A name that resolves as a skill is sent to the agent, which may then read
  a file] → the message is ordinary user text; the agent's `read` gating and
  the existing confirmation rules apply unchanged.
- [Case folding is ASCII-only in Lua] → a skill whose directory name carries
  non-ASCII letters stays effectively case-exact; skill names are
  conventionally ASCII kebab-case, so a Unicode folding table is not worth
  carrying here.
- [Removing a `palette_mode` branch touches shared key/mouse code] → the
  `command` mode stays the default and the removed guards are covered by the
  rewritten palette tests.
- [A terminal too short for the footer already overlaps regions] → not fixed
  here; the window and the indicator are guarded so they never paint over the
  separator or the status line, and shortening the window is what keeps a
  short terminal usable in the common case.

## Migration Plan

Single change, no stored state to migrate. The only user-visible break is the
`/skills` command; its replacement path is documented. Rollback is a revert
of the change.

## Open Questions

- Whether built-in commands should later accept real arguments (for example
  `/model <id>`) is deferred; it would add hints and argument handling, and
  it changes neither the specs nor the approach here.
