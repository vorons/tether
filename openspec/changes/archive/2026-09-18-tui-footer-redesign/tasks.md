# Tasks

## 1. Layout: separator row

- [x] 1.1 Add `separator_row = S.h - 1` to `layout()` in `src/tether/ui.lua`; keep `status_row = S.h`
- [x] 1.2 Paint the separator in `render_input()`: a dim `─` row (ASCII: `-`) spanning `L.w` at `L.separator_row`, before input lines
- [x] 1.3 Confirm the transcript height math accounts for the new fixed row (input + palette + error + 1 was already the fixed count — verify it still holds with `alt_screen=false`)

## 2. Compact status line (5b)

- [x] 2.1 In `render_status()`, build the mandatory parts list in order: `spinner Ns` (busy only), `model`, `workspace`, `token usage`
- [x] 2.2 Make `🖱 <mode>` conditional on a fade timer (`S._mouse_flag_until`, set in `mouse_update_tracking()` when the effective mode changes, 3 s window via `os.time()`)
- [x] 2.3 Make `⌨ <proto>` conditional on `S.kb_protocol ~= 0`
- [x] 2.4 Toast stays first in the parts list, one-shot, cleared by next keypress (existing behavior — verify)
- [x] 2.5 Truncate overflow from the right; keep the status line on one row

## 3. Scroll indicator label

- [x] 3.1 Change `↓ новые +N` to `↓ +N` in `render_status()` and in the in-transcript marker (`render_transcript()` region ~line 1777)
- [x] 3.2 ASCII twin: `v +N` instead of `v новые +N`
- [x] 3.3 Update tests that hard-code `новые`

## 4. Tests

- [x] 4.1 Separator row: rendered at `S.h - 1`, dim, ASCII variant uses `-`
- [x] 4.2 Status line default idle: `model · ws · tokens` only, no flags
- [x] 4.3 Mouse flag: visible right after a mode change, gone after the fade window
- [x] 4.4 kb flag: present when `kb_protocol` is 1 or 2, absent when 0
- [x] 4.5 Scroll indicator: `↓ +N` in both places, ASCII `v +N`

## 5. Spec sync

- [x] 5.1 After implementation, verify the delta spec in `specs/tui/spec.md` matches observed behavior (especially the fade-window duration and truncation order)
