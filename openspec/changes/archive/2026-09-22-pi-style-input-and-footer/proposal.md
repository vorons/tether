# Proposal

## Why

tether's bottom area has drifted into a compromise: the input is a bare block
whose first row is marked with `› `, one full-width dim rule sits under it, and
a single reverse-video status row mixes persistent facts (model, workspace,
context usage) with transient state (spinner, pending retry, toast, mouse and
keyboard flags). Nothing marks where the input ends, and every new transient
flag gets bolted onto the one row that also carries the model name.

pi's fullscreen mode already solved this split, and tether's own ask/confirmation
work has been borrowing from pi's interaction patterns. Its design is a framed
input box whose **top rule carries the turn status** (spinner, retry, scroll
label) and a **two-line dim footer** that keeps persistent facts only — the path
on line 1, token stats left and the model right-aligned on line 2. Adopting it
removes the reverse-video bar, gives the input a frame that grows cleanly with a
multi-line prompt, and stops transient state from sharing a row with the model.

## What Changes

- **Input field becomes a framed box.** A dim rule spans the width above the
  input, the text rows render with horizontal padding, and a dim rule closes the
  box below. The `›` marker is dropped: the box itself delimits the input.
- **Caret becomes a reverse-video block** drawn on the cell under the cursor
  (pi's editor), instead of positioning the hardware terminal cursor. The
  hardware cursor stays hidden outside overlays.
- **The top rule carries the turn status**: spinner + elapsed seconds while a
  turn runs, and the pending retry (attempt, wait) while the agent waits between
  attempts. Both leave the footer.
- **Scroll labels in the rules**: when the input is windowed, the top rule shows
  a centered `↑ N more` and the bottom rule a centered `↓ N more`.
- **Footer replaces the reverse-video status bar** with dim rows: line 1 is the
  workspace path (`~`-abbreviated); line 2 is `↑in ↓out` counters followed by
  the existing context cell (`used/max (pct%)`, same green/yellow/red
  thresholds) on the left, with the model name right-aligned at least two
  columns away. An optional third plain row carries transient flags (toast,
  mouse mode, keyboard protocol, scroll indicator) only while one is active.
- **New setting** `ui.editor_padding_x` (0–3, default 0) for the box's
  horizontal padding.
- **Palette placement**: the slash dropdown renders below the box's bottom rule
  instead of above the removed separator row.
- **BREAKING (spec-level)**: the `Footer separator` and `Token usage in status
  line` requirements are removed; their guarantees move into the new `Footer`
  requirement and the layout budget in `Screen regions`.

Non-goals (pi shows them, tether has no data for them): git branch, session
name, cache read/write token columns, cost, and thinking level.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `tui`: the bottom region is redefined — `Screen regions` (footer budget), a new
  `Footer` requirement, `Input field and history` (framed box, block caret,
  scroll labels), `Live turn feedback` and `Retry and continuation notices`
  (turn status moves into the input box's top rule), `Scroll position indicator`
  and `Palette` (indicator and dropdown land in the new region), and removal of
  `Footer separator` and `Token usage in status line`.
- `config`: `ui.editor_padding_x` joins the `Defaults` set.

## Impact

- `src/tether/ui.lua` — layout budget, input rendering, caret placement, footer
  rendering (replacing `render_status`), palette region.
- `src/tether/config.lua` — the `ui.editor_padding_x` default.
- `openspec/specs/tui/spec.md`, `openspec/specs/config/spec.md` — requirements
  above, once archived.
- `tests/lua_tests.lua` and the TUI frame tests — layout, caret, footer and
  rule-content assertions.
- `README.md` and `docs/tech-spec.md` — the described bottom-of-screen layout.
