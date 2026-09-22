# Tasks

## 1. Configuration and glyph data

- [x] 1.1 Add `editor_padding_x = 0` to the `ui` defaults in `src/tether/config.lua`, with a config test (in `tests/lua_tests.lua`) asserting the default and that a partial `ui` override keeps it
- [x] 1.2 Add the new row glyphs and labels to `ui.lua`'s constants section — the box rule (`─` / `-`), the scroll labels (`↑ N more` / `^ N more`, `↓ N more` / `v N more`), and the footer arrows (`↑`/`↓` vs `^`/`v`) — and verify the ASCII twins resolve through the existing ASCII test

## 2. Dock layout

- [x] 2.1 Rewrite the footer budget in `layout()` as `1 (top rule) + input_h + palette_h + 1 (bottom rule) + 2 (footer rows) + flags_h`, replacing `separator_row`/`status_row` with the top-rule, bottom-rule, path, stats and flag rows, and keeping the error banner above the box; verify with a frame test that addresses the new rows for an empty input, a multi-line input, an open palette and a visible error banner
- [x] 2.2 Verify the flag row's elasticity: a frame with no active flag has no flag row, a frame with an active flag has exactly one, and the transcript height differs by the same number of rows in each case with no region overlap

## 3. Input box

- [x] 3.1 Render the box in place of `render_input`'s prefixed rows: a dim top rule spanning the width, content rows inset by `ui.editor_padding_x` and padded out to the content width, a dim bottom rule, and no `›` marker; verify with frame tests for padding 0 and 2, for every row having equal display width, and for the `-` rule in ASCII mode
- [x] 3.2 Draw the centered `↑ N more` / `↓ N more` labels in the rules from the window's hidden-row counts, omitting a label when the rule cannot hold it; verify with frame tests for a scrolled window, for a hidden-above-only window, and for a narrow terminal
- [x] 3.3 Replace the hardware cursor with the block caret: paint the character under the cursor (or a reverse-video space at the end of a row) inside `render_input`, fold the shared window computation into it, and delete `place_cursor` and its `ESC[?25h`; verify with frame tests asserting the caret cell for a mid-row cursor, an end-of-row cursor, and a Cyrillic cursor offset, plus a test that no frame emits a cursor-show escape

## 4. Turn status in the top rule

- [x] 4.1 Paint the busy spinner with elapsed seconds in the top rule while a turn runs, and clear it when the turn ends (reply, error, abort, confirmation raised); verify with frame tests for the busy frame and for the frame after each end path
- [x] 4.2 Paint the pending retry (`↻ повтор N · Xs`) in the top rule in place of the turn indicator while the agent waits, restoring the ordinary indicator on the next attempt; verify with a frame test for the waiting frame and the frame after the wait
- [x] 4.3 Verify the rule degrades safely: with a long status on a narrow terminal the rule stays a single row truncated to the width, and with a hidden-row label that does not fit the label is dropped while the status stays

## 5. Footer

- [x] 5.1 Accumulate session input/output tokens from `usage` events (`prompt_tokens`, `completion_tokens`) into new state, leaving `S.tokens_used` as the context estimate; verify with a unit test that feeds two usage events and checks the totals
- [x] 5.2 Implement the compact counter formatter and the stats-row composition (counters, the existing `M.token_usage` context cell, the right-aligned model at least two columns away, model truncated from its left before the left side is truncated); verify with unit tests covering each count magnitude, the two-column gap, and both truncation orders
- [x] 5.3 Render the path row (`~`-abbreviated workspace, dim, truncated with a dim `...`) and the optional flag row (toast, mouse, keyboard, scroll flags joined by one space, not dim as a whole, truncated with a dim `...`); verify with frame tests for the idle footer, the flags row appearing for each flag, and the ASCII arrows
- [x] 5.4 Remove `render_status` and the reverse-video status row, and verify no footer row is painted in reverse video in any frame test

## 6. Palette placement

- [x] 6.1 Move the palette window and its overflow indicator to start directly below the box's bottom rule, keeping them inside the reserved rows and never over the rules or the footer; verify with the palette frame tests for the open window, the overflow indicator, and a short terminal

## 7. Documentation

- [x] 7.1 Update the bottom-of-screen description in `README.md` and `docs/tech-spec.md` (input box, block caret, footer rows, `ui.editor_padding_x`) and verify the described rows match a rendered frame

## 8. Verification

- [x] 8.1 Run `make test` and verify every check passes: `luac -p` on every module, `tests/lua_tests.lua`, the context tests, the e2e script, and the host smoke/primitives binaries
- [x] 8.2 Drive the real TUI headlessly against a stub model with a captured frame dump and verify the box's two rules, the padded text rows, the block caret, and the two footer rows are present in the captured frames, and that a submitted message still reaches the agent
- [x] 8.3 Run `openspec validate pi-style-input-and-footer --strict` and verify the change validates
