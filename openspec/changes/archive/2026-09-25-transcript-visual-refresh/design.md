# Design: Transcript visual refresh

## Rendering pipeline (recap)

`render_entry(e, width)` (ui.lua) is injected into `transcript` via
`transcript.configure({ render = render_entry })` (ui.lua:2280). `transcript`
owns the row cache and the height index; `render_all` / `row_text` both go
through `entry_rows` → `render_fn`, so virtualization is provably parity-safe
(T61/T62).

## A. Gaps between entities

Gap is a property of the *transition* into an entry, decided from the previous
entry's role.

- Change the `render_fn` contract to `render_fn(e, width, prev_role)`.
- `transcript.entry_height` (transcript.lua:380) and `entry_rows` (transcript.lua:422)
  receive `prev_role` from `entry_at(i - 1)` at every call site (`ensure_index:460`,
  `row_text:492`, `render_all:504`). The row cache key gains `rows_prev`; when
  `prev_role` differs the entry is re-rendered. Roles are assigned at append and
  never mutated; structural removals (`retry` drop, `restore_dropped`) already
  call `M.invalidate()` (bumps every version), so the cache stays correct.
- `render_entry` computes `need_gap`:
  - `false` for virt tails (`ask`/`confirm`/`placeholder`) — they already emit a
    leading `""` themselves;
  - `false` when `prev_role` is nil (first entity);
  - `false` when the current role is not in
    `{separator, user, assistant, system}`;
  - `false` when `prev_role == "separator"` (the user row directly follows its
    separator — no double gap);
  - otherwise `true`.
- When `need_gap` and the rendered rows are non-empty, prepend `cfg.ui.block_gap`
  empty rows (`""`) at the front of `out`. Empty assistant entries (`{}`) get no
  gap. `block_gap` default 1, 0 ⇒ today's behaviour.

## B. Code blocks (box frame, off-by-one + dim)

In `md_render` (ui.lua:661):
- Top border (ui.lua:680-681): `math.max(inner - ulen(lang), 1)` →
  `math.max(inner + 1 - ulen(lang), 1)` so the top edge is `inner + 4` columns,
  matching the bottom edge (`inner + 2` fill, ui.lua:704) and body rows.
- Dim the frame: top = `dim(box.tl .. box.h .. " ") .. fence .. dim(" " .. rep .. box.tr)`;
  bottom = `dim(box.bl .. rep(box.h, inner + 2) .. box.br)`; body sides =
  `dim(box.v) .. " " .. seg .. " " .. dim(box.v)`. `vlen`/`wrap` are SGR-aware,
  so widths are unchanged.
- Fence detection (ui.lua:675): `^%s*```(.*)$`, language = first
  `[%w%+%.#%-]+` token of the remainder; closing fence `^%s*```%s*$`.

## C. Markdown-lite

Add `md_ansi(kind, text)` (kind ∈ `code`/`bold`/`italic` → `sgr_role`) and pass
it as `ansi_fn` to `md_render` at both call sites (assistant body ui.lua:2191,
ask description ui.lua:2081). `md_strip_inline` already accepts `ansi_fn`.

- Headings (ui.lua:707): wrap the stripped+effect-rendered text
  (`wrap(md_ansi(...), width)`) and colour it with the `heading` role; drop the
  unconditional trailing blank (collapse handles spacing).
- Tables: consecutive source lines beginning with `|` form a block. Compute per-
  column max `vlen`, pad cells left, join with ` │ ` (`|` in ASCII). A separator
  row (`|---|`) renders as a dim `─` rule. Clip the whole table to `width`.
- Ordered lists (ui.lua:712): add a `%d+%.%s+` branch alongside `-`/`*`;
  continuation indent aligns to the first-line prefix width.
- List prefix (ui.lua:715): `"  • "` (4 cols) → `"• "` (2 cols); continuation
  indent `string.rep(" ", prew)` becomes 2 spaces.
- Blank-run collapse: after building `out`, collapse runs of `""` to a single
  `""`, drop leading `""`, and drop trailing `""` (so the entity-level gap in A
  is not doubled).

## D. Theme roles

`THEMES` (ui.lua:123): add `code = "35"` and `heading = "36;1"` to `default` and
`solarized`; `mono` keeps an empty table (no SGR).

## E. Gap above the input box

`layout()` (ui.lua:1237-1282): reserve one extra row. With `error_h`:
`error_row = 1 + th`; `gap_row = 1 + th + error_h`; `rule_top_row = 2 + th + error_h`.
`reserve(pal_h) = 2 + shown_in + pal_h + 1 + 1`. `redraw()` calls
`set_row(L.gap_row, "")` so a stale row cannot survive a height shrink.

## F. Tool name colour

ui.lua:2216 `yellow(e.name or "?")` → `sgr_role("accent", e.name or "?")`. Keep
`yellow` for the `…` pending marker and the `⚠` confirm label. Update
`docs/design.md` (tool name row, §6.14 table).

## G. Slash palette

- ui.lua:2690: `w = max over S.palette_items of vlen(label .. (hint and " " .. hint or ""))`
  (computed once per paint); format `string.format(" %-*s %s", w, label, it.desc or "")`.
- ui.lua:1317 `PALETTE_SKILL_HINT = "[задача]"` → `"[skill]"`.

## Config

`src/tether/config.lua` `ui` block: add `block_gap = 1`.

## Risks

- Row-cache correctness across gap: closed by threading `prev_role` and storing
  `rows_prev`; roles immutable; removals invalidate all versions.
- SGR inside markdown does not break `vlen`/`wrap` (covered by T39/T54).
- Hooks/agent/provider/transport contracts unchanged.
