# Tasks

## 1. Window and height

- [x] 1.1 Add the row-count rule to `layout()`: `min(8, floor(terminal height / 2))` with a floor of 1, published as `L.palette_rows`, and keep `palette_h` at `rows + 2` (blank lead-in, candidates, trailing row)
- [x] 1.2 Add a `palette_window(L)` helper implementing pi's formula (centred while there is room, clamped at both ends) and use it in `render_palette()` in place of the fixed `1..shown` loop
- [x] 1.3 Verify with a test that a list longer than the window renders the selected candidate after enough `↓` presses, and that the first row is no longer candidate 1 (T118)

## 2. Indicator and no-match row

- [x] 2.1 Render `(n/total)` in the block's trailing row when any candidate is hidden (`start > 1` or `end < #items`), with `n` the selection position; verify T118 asserts `(1/27)` then `(13/27)`, and T119 that nothing is rendered when everything fits
- [x] 2.2 Set `S.palette_empty` in `palette_sync()` (palette open, no candidates) and render a single `нет совпадений` row from it, leaving `palette_items` empty so Enter still does nothing
- [x] 2.3 Verify T120 asserts the placeholder row is drawn, that `#palette_items == 0`, and that Enter neither runs a command nor submits the input

## 3. Interaction paths

- [x] 3.1 Map a mouse click to a candidate through the same window (window-relative row) instead of the fixed offset
- [x] 3.2 Make a click on a skill row substitute `/<name> ` like Enter, instead of calling `execute_command(nil)`
- [x] 3.3 Verify T122 clicks a row inside a scrolled window (candidate 11 of 27), asserts `/sk4 ` lands in the input, and that clicks on the lead-in and indicator rows are inert

## 4. Verification

- [x] 4.1 Add a height test (T121): on a 12-row terminal the palette draws at most 6 candidate rows, the transcript keeps a row, the input block stays above the separator and the status line stays on the last row
- [x] 4.2 Run `make test` and verify luac, unit, context, e2e and host smoke all pass
- [x] 4.3 Run `openspec validate palette-scrolling --strict` and verify it passes
- [x] 4.4 Check the built binary under a pty with 14 skills: the palette scrolls to the selected skill and shows `(13/21)`; on a 10-row terminal it draws 5 rows (half the height) with the status line still painted; on a 30-row terminal it draws 8; a `/zzz` filter shows `нет совпадений`

## 5. Docs

- [x] 5.1 Document the palette window, height cap and indicator in `docs/design.md` §6.8 and mention the scroll behaviour in `README.md`
