# Design: palette-scrolling

## Context

`layout()` reserves a palette block of `min(#items, 8) + 2` rows and
`render_palette()` draws `min(#items, palette_h - 2)` rows starting at candidate
1. The extra two rows are one blank above the candidates and one blank below.
The selection (`S.palette_sel`) is clamped to the candidate count but never
brought into view, and the mouse click path maps a screen row to a candidate with
the same fixed offset.

`pi`'s `SelectList` (`packages/tui/src/components/select-list.ts`) computes a
window instead of a prefix: `getVisibleRange()` picks
`start = max(0, min(selected - floor(maxVisible / 2), len - maxVisible))` and
`end = min(start + maxVisible, len)`, draws only that slice, and appends a
`  (selected+1/len)` line when anything is hidden.

## Decisions

### D1 — Adopt pi's window formula verbatim

```lua
start = S.palette_sel - math.floor(rows / 2)      -- centred …
if start < 1 then start = 1 end                   -- … clamped at the first row
if start > n - rows + 1 then start = n - rows + 1 end  -- … and at the last
```
Centring while there is room and clamping at the ends is the behaviour users
already know from `pi`, and it keeps the common case (selection near the first
rows) identical to today's rendering.

*Rejected:* minimal scrolling (move the window only when the selection leaves
it) — it needs the previous window as state and drifts when the filter shrinks
the list; the pure function of `(selection, count, rows)` is simpler and is what
the reference does.

### D2 — Height: `min(8, floor(h / 2))`, floor of 1

Eight stays the ceiling (the current look on a normal terminal); the terminal
height cap is what stops a short terminal from pushing the input block off the
screen, since `layout()` subtracts the palette block from the transcript height
and `th` is floored at 1. The layout publishes the chosen row count as
`L.palette_rows` so the renderer and the click mapping share one number instead
of recomputing it from `palette_h - 2`.

### D3 — The indicator reuses the trailing blank row

The palette block is `rows + 2`: a blank lead-in, the candidate rows, and a
trailing blank. When candidates are hidden the trailing blank becomes the
indicator, so the frame does not grow and `palette_h` stays a pure function of
the row count and the candidate count. The indicator is `(n/total)` with `n` the
selection — the same shape `pi` renders.

*Rejected:* a fixed extra row always reserved for the indicator — it wastes a
row of transcript in the common case where nothing is hidden.

### D4 — No match: a placeholder row, not a selection

An empty filter result leaves `palette_items` empty, which the Enter path already
treats as "nothing to run" and the "no match" scenario depends on. The change
therefore renders a `нет совпадений` row from a separate `S.palette_empty` flag
instead of inserting a pseudo-candidate, so no code path can select or execute
the placeholder.

### D5 — Clicking a skill row follows Enter

The click path still called `execute_command(it.cmd)`, which is nil for a skill
row (the skills change introduced those rows and only wired the keyboard). It now
mirrors the keyboard branch: a skill row substitutes `/<name> `, a command row
runs the command.

## Interaction with the open `skills-in-main-palette` change

Both changes MODIFY the same `Palette` requirement of `tui`. This delta carries
the merged text — the skills rows, the `/name ` substitution and the submit rule
from that change, plus this change's window, indicator, height cap and no-match
row — so archiving them in either order leaves the requirement whole.

## Risks

- **Selection visible but the indicator off by one.** The indicator's `n` is the
  selection position, not the window offset; a test pins `(8/12)` for the eighth
  of twelve candidates.
- **A one-row palette on a tiny terminal.** `rows` floors at 1 so the block
  stays 3 rows and `layout()` still has a positive transcript height.
- **Existing render tests** assert rows for the palette; they keep passing
  because a list that fits is still drawn from the first candidate.
