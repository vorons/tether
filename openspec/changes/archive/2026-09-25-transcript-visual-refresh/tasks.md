# Tasks: Transcript visual refresh

## 1. Entity gaps (transcript + ui)

- [x] Extend `render_fn` contract to `render_fn(e, width, prev_role)` in
      `transcript.lua` (`entry_height`, `entry_rows`) and thread `prev_role` from
      `entry_at(i - 1)` at `ensure_index`/`row_text`/`render_all` call sites.
- [x] Add `rows_prev` to the row cache key so a changed predecessor re-renders.
- [x] In `render_entry`, compute `need_gap` (separator/user/assistant/system, not
      after a separator, not first entity, not virt tails) and prepend
      `cfg.ui.block_gap` empty rows when the entry renders non-empty.

## 2. Code block frame

- [x] Fix top-border width off-by-one in `md_render` (ui.lua:681).
- [x] Dim the frame (top label, bottom, side rails) with readable language label.
- [x] Recognise fences with trailing attributes and unknown-lang names
      (`^%s*```(.*)$`).

## 3. Markdown-lite

- [x] Add `md_ansi` and pass `ansi_fn` to `md_render` at assistant (ui.lua:2191)
      and ask (ui.lua:2081) call sites.
- [x] Headings: wrap + `heading` role colour, drop unconditional blank.
- [x] Tables: aligned columns, dim separator rule, width clip.
- [x] Ordered lists: `%d+%.%s+` branch, aligned continuation.
- [x] List prefix `"  • "` → `"• "` (2-col continuation).
- [x] Collapse blank-run passes (single + trim leading/trailing).

## 4. Theme roles

- [x] Add `code = "35"` and `heading = "36;1"` to `default`/`solarized` THEMES
      (ui.lua:123); `mono` unchanged.

## 5. Input-box gap

- [x] `layout()`: reserve +1 row, `error_row = 1+th`, `gap_row = 1+th+error_h`,
      `rule_top_row = 2+th+error_h`.
- [x] `redraw()`: `set_row(L.gap_row, "")`.

## 6. Tool name + palette

- [x] ui.lua:2216 `yellow(e.name)` → `sgr_role("accent", ...)`.
- [x] ui.lua:2690 dynamic label-column width from `vlen(label .. hint)`.
- [x] ui.lua:1317 `PALETTE_SKILL_HINT` `"[задача]"` → `"[skill]"`.

## 7. Config + docs + spec

- [x] `config.lua` `ui` block: `block_gap = 1`.
- [x] `docs/design.md`: §6.3 block spacing, §6.14 tool name / hint.
- [x] `README.md` / `docs/tech-spec.md`: `[задача]` → `[skill]`.
- [x] Highlight aliases (`javascript py tsx jsx shell zsh c++ cpp cc cxx rs
      golang`) map to the canonical tokenizers; `yaml`/`yml`/`rb` highlight
      string literals and numbers (no keyword set); delta wording reconciled
      with the "Unknown language stays plain" scenario.
- [x] `openspec/specs/tui/spec.md` delta: Markdown-lite, Code block highlighting,
      Turn separators, Retry notices, Palette, Themes.

## 8. Tests

- [x] Update T32/T54 (heading/code row counts, bullet indent 4→2).
- [x] Update T61/T62 (separator/user gap parity).
- [x] Update T80/T83 (`[задача]` → `[skill]`).
- [x] Update pi 2.1 layout assertions (`rule_top_row = error_row + 2`).
- [x] Run `lua tests/lua_tests.lua` and fix any remaining row-index assertions.
