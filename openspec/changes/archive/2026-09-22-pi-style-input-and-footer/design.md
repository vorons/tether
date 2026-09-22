# Design

## Context

See `proposal.md` — Why for the motivation. What shapes the approach is the
current implementation:

- `src/tether/ui.lua` paints into a row buffer (`set_row`, row diff by comparing
  content, `frame_start` hides the cursor with `ESC[?25l`) and computes the
  bottom region once in `layout()`: the budget is
  `input_h + palette_h + error_h + 1 (separator) + 1 (status)`, with
  `separator_row = S.h - 1` and `status_row = S.h`.
- `render_input` paints the input rows with a `› ` prefix on the first line,
  `render_status` paints one reverse-video row of ` · `-joined parts, and
  `render_palette` paints its window between the input rows and the separator.
- `place_cursor` positions the hardware terminal cursor and shows it
  (`ESC[?25h`) for the composer; it is the only cursor-show escape in the TUI,
  and overlays never showed the cursor at all.
- The status row is the only place the spinner/elapsed (`S.busy`,
  `S.busy_started_at`), the pending retry (`S.retry_wait`), the one-shot toast,
  the mouse/keyboard flags and the scroll indicator live.
- Usage events carry `used` (kept as the context estimate in `S.tokens_used`)
  plus `prompt_tokens` and `completion_tokens`; `M.token_usage` renders
  `used/max (pct%)` with the green/yellow/red thresholds.
- Reference design (pi, read from `packages/tui/src/components/editor.ts`,
  `editor-component.ts`, and
  `packages/coding-agent/src/modes/interactive/components/{footer,custom-editor,status-indicator}.ts`):
  a borderless-side editor box whose top rule embeds the working/retry status
  (`── ⠋ Working… ────`) and whose rules carry centered `↑ N more` / `↓ N more`
  labels, a reverse-video block caret, `editorPaddingX` 0–3, and a two-line dim
  footer (`~/pwd (branch) • session`, then stats left with the model
  right-aligned), plus an optional third line for extension statuses.

## Goals / Non-Goals

**Goals:**

- Make the input a framed box whose rules and padding are computed by the same
  layout that owns the dock budget, so input height, palette, error banner and
  resize cannot desynchronize the regions.
- Separate persistent facts (path, tokens, model) from transient state (turn
  progress, retry, flags) into different rows.
- Keep every existing configuration key meaning what it meant, adding exactly
  one new key.

**Non-Goals:**

- No new data sources: no git branch, session name, cache-read/write columns,
  cost, or thinking level (pi shows them; tether has no data).
- No change to history navigation, key bindings, the transcript regions, the
  ask block's own editors (they keep their `caret_glyph`), or mouse handling.
- No theme work beyond the rules being dim in every theme.

## Decisions

**1. Box geometry: rules above and below, no side borders, `ui.editor_padding_x`.**

Content width is `w - 2 * pad`, clamped so at least one column remains; the
value is clamped to 0–3 (pi's `editorPaddingX` range) and the user keeps pi's
default of 0. Text rows are padded out to the content width so the rules and the
text rows have identical display width — the row diff then never sees a ragged
row. Alternatives: side borders (costs two columns and diverges from pi); keeping
the `›` marker inside the box (the user chose to drop it — the rules already
delimit the input).

**2. The box's bottom rule is the old separator row.**

The dock budget becomes `1 (top rule) + input_h + palette_h + 1 (bottom rule) +
2 (footer rows) + flags_h`, where `flags_h` is 1 while at least one flag is
active and 0 otherwise; the error banner keeps its row above the box. The
palette's window starts directly below the bottom rule (pi's dropdown renders
below the editor's bottom border) instead of above the separator. Alternatives:
keep a separate separator under the box (two identical rules a row apart);
keep the palette inside the box (it would sit between the input rows and the
closing rule, which reads as part of the input).

**3. Block caret replaces `place_cursor`.**

`render_input` paints the reverse-video cell itself: the character at the cursor
offset, or a reverse-video space when the cursor is at the end of a row. The
window computation currently duplicated between `render_input` and `place_cursor`
collapses into `render_input`. `place_cursor` and its `ESC[?25h` disappear, so
the hardware cursor stays hidden for the whole session (overlays never showed it,
and the exit sequence still restores it). The ask block's freeform/note editors
are unaffected: they draw `caret_glyph()` inside the transcript block. Note the
caret must be one character wide for UTF-8 input, using the same byte-offset
helpers the cursor movement uses. Alternative: keep the hardware cursor (the user
chose the pi look; a block caret also keeps the caret visible in frames captured
by tests and by the debug dump, where the hardware cursor is invisible).

**4. Turn status lives in the top rule.**

The top rule is composed as `── ` + status + ` ` + fill when a status is
present, where the status is the spinner with elapsed seconds while busy, or the
retry text (`↻ повтор N · Xs`) while waiting between attempts; the status keeps
its accent/muted roles and its Russian wording. The `↑ N more` label is centered
in the rule only when it fits with at least one column of gap after the status;
otherwise the status alone is painted, and the rule degrades to a plain fill.
The whole rule is truncated to the width, so it never wraps. Alternatives:
putting the elapsed field back into the footer (the user chose the rule); pi's
exact precedence (it collapses the status to a bare spinner before dropping the
overflow label) — tether keeps the more readable status text instead.

**5. Footer rows carry only persistent facts.**

Row 1 is the `~`-abbreviated workspace, truncated with a dim `...`. Row 2 is:
`↑<in> ↓<out>` (each omitted while zero) accumulated per session from
`usage.prompt_tokens`/`completion_tokens` into new `S.tokens_in`/`S.tokens_out`,
followed by the unchanged `M.token_usage` context cell, with the model name
right-aligned at least two columns away. The compact counter form mirrors pi's
`formatTokens` (plain below 1000, one decimal with `k`, rounded `k`, `M`).
When both sides cannot fit, the model name is truncated from its left so its tail
survives, and dropped when nothing of it fits; the left side is truncated only
when it alone exceeds the width. Alternatives: pi's full stats line (needs cache
and cost plumbing tether does not have) and tether's `model · workspace ·
used/max` order on one row (that is the mixing this change removes).

**6. Flags move to an optional third footer row.**

The toast, mouse flag, keyboard flag and scroll indicator keep their existing
state and wording, joined by one space on a row that exists only while one is
active; that row is not dim as a whole (each flag carries its own presentation)
and is truncated with a dim `...`. Pi's extension-status line behaves the same
way. Alternative: reserve the row permanently to avoid a dock-height change on
every toast — recorded as the fallback if the reflow proves distracting; the
transcript height is already elastic (input growth changes it), and every flag is
short-lived.

**7. `ui.input_max_lines` stays the window size.**

Pi sizes its editor window as `max(5, floor(rows * 0.3))`; tether keeps its own
setting so existing configuration and its spec scenarios keep their meaning, and
adopts only the `↑ N more` / `↓ N more` labels for the window's hidden rows.
Alternative: adopt pi's formula (silently overrides a documented setting).

**8. ASCII mode keeps text-only output.**

The rules use `-`, the scroll labels use `^ N more` / `v N more`, and the footer
arrows use `^` and `v`. The block caret is a video attribute, not a glyph, so it
needs no ASCII twin.

## Risks / Trade-offs

- **Dock reflow when the flags row appears or disappears** → it is one row, the
  flags are short-lived, and the transcript height is elastic by design; the
  fallback is to reserve the row permanently.
- **A long retry status on a narrow terminal** → the rule truncates and never
  wraps; the retry row in the transcript still carries the full text.
- **Losing the `›` affordance** → the two rules and the block caret identify the
  input; a user who wants the inset can set `ui.editor_padding_x`.
- **Block caret and wide characters** → the caret must cover the character at
  the cursor offset, not one byte; covered by the UTF-8 helpers already used for
  cursor movement, and by a test with Cyrillic input.
- **Tests and code referencing the removed rows** (`S.status_row`,
  `separator_row`, `render_status`, `place_cursor`, `›`) → rename and re-assert
  them in the same change; the frame tests must assert the new row order, the
  caret cell, and the footer layout.

## Migration Plan

- No data or session migration. `ui.input_max_lines` and every other existing key
  keep their meaning; `ui.editor_padding_x` defaults to 0, so an unmodified
  config renders the new box with the text flush to the rules.
- Rollback is a revert of `src/tether/ui.lua` and the default added to
  `src/tether/config.lua`; no persisted state is involved.
