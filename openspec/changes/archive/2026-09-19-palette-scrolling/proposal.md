# Proposal: palette-scrolling

## Why

The slash palette draws a fixed window of at most eight candidates and always
starts at candidate 1 (`ui.lua:1061-1063`, `ui.lua:1927-1934`). With the seven
commands ahead of them, discovered skills begin at row 8: only the first skill is
ever visible, and pressing `↓` past the window moves the accent to a row that is
not drawn at all. The list is not static — there is simply no scroll window and
no indication that rows are hidden.

The reference implementation (`pi`, `packages/tui/src/components/select-list.ts`)
solves this with a window that follows the selection plus a `(n/total)` indicator
and a height cap derived from the terminal, which is what this change adopts.

## What Changes

- **The visible window follows the selection.** Only `min(8, floor(terminal
  height / 2))` rows are drawn, and the window is chosen so the selected row is
  inside it: centred while there is room on both sides, clamped at the first and
  last candidate otherwise (the `SelectList.getVisibleRange` formula).
- **A `(n/total)` indicator is rendered when rows are hidden**, in the trailing
  row of the palette block that is blank today, so the frame does not grow.
- **The height respects the terminal.** A short terminal now shrinks the palette
  instead of pushing the input block off the screen; a tall one still shows at
  most eight rows.
- **An empty filter result says so.** A filter with no match renders a single
  `нет совпадений` row instead of an empty block. The row is not selectable:
  Enter still neither runs a command nor submits the input.
- **Clicking a skill row behaves like Enter on it** (substitutes `/<name> `),
  matching the row semantics introduced with the skills change.

## Capabilities

### New Capabilities
- None.

### Modified Capabilities
- `tui`: the palette windows its rows around the selection, caps its height by
  the terminal, shows a scroll indicator, and renders a no-match row.

## Impact

- Code: `src/tether/ui.lua` — `layout()` (palette height + row count),
  `render_palette()` (window, indicator, no-match row), `palette_sync()`
  (`palette_empty`), and the mouse click mapping (window-relative row).
- Tests: `tests/lua_tests.lua` — the palette rendering tests, plus new coverage
  for windowing, the indicator, the height cap and the no-match row.
- Docs: `docs/design.md` §6.8 and `README.md` describe the palette window.
- No config, wire-format or agent behavior change.
