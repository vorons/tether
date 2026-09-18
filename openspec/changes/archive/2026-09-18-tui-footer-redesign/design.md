# Design

## Context

`src/tether/ui.lua` already has a single-pass `layout()` that returns the
row map (`transcript_row`, `input_row`, `palette_row`, `status_row`,
...) for one frame, and `render_status(L)` composes the status line from
a list of parts joined by ` · `. The input renderer writes `›`-prefixed
lines into `L.input_row..L.input_row+input_h-1`. The scroll indicator
today prints `↓ новые +N` and the status line always carries `🖱 mode`
and `⌨ proto` when mouse is on or a protocol was detected.

The existing spec (`tui`) has three requirements we touch:
- Screen regions (layout contract),
- Token usage in status line (the 4-part composition),
- Scroll position indicator (the `↓ +N` label).

## Goals / Non-Goals

**Goals:**
- Visual break between input and status without costing >1 row.
- Lean default status line: mandatory parts only; flags fade.
- ASCII-safe: every new glyph has a `-`/`v` twin.
- No new config key. (A `ui.status_flags = "legacy"` escape hatch is
  deferred to a follow-up change if requested.)

**Non-Goals:**
- No two-row footer (F3 was considered and rejected in explore).
- No re-styling of the input prefix or transcript roles.
- No word-level diff overlay, no theme data changes, no new syntax
  languages — those are separate changes (3/4 in the explore notes).

## Decisions

**D1. Separator row is layout-owned, not paint-owned.**
`layout()` gains `separator_row = S.h - 1` and `status_row = S.h`.
The separator is drawn in `render_input()` (one extra `set_row` before
the input). Cost: 1 call per frame. Alternative considered: paint it
in `render_status()` — rejected, it would make the status line
"taller" and would not survive input-height changes uniformly.

**D2. Fade timers on S, not on a background thread.**
`tether` has no event-loop timer; the main loop is the timer.
New fields on `S`:
```
S._mouse_flag_until = 0   -- os.time() when the flag should drop
S._kb_visible       = nil -- recompute each frame from kb_protocol
```
- `mouse_update_tracking()` (existing) already fires on mode change;
  when it changes the effective mode, set `_mouse_flag_until =
  os.time() + 3`.
- `render_status()` appends the mouse part only while
  `os.time() < S._mouse_flag_until`.
- The kb part stays visible only when `S.kb_protocol ~= 0` (current
  behavior minus the "always on" default when `mouse=off` is off the
  line — check the existing gate at line 1929 and move it inside the
  flag condition).

Alternative considered: a per-frame counter on `S.busy` instead of
`os.time()` — rejected because a long blocked turn would keep the flag
alive; `os.time()` is correct even when the event loop is idle.

**D3. Toast order stays unchanged.**
Toast continues to lead the status line and is cleared by the next
keypress (existing one-shot). No new part.

**D4. Overflow truncation order.**
Mandatory parts truncate first: drop from right to left
(`kb` flag, `mouse` flag, scroll, token, workspace, model, spinner).
Rationale: model name is the most useful anchor, spinner only
appears while busy.

**D5. `↓ +N` vs `↓ новые +N` is a label-only change.**
Only the literal in `render_status()` and the in-transcript marker in
`render_transcript()` change. The scroll indicator math is unchanged.

## Risks / Trade-offs

- **`os.time()` resolution** is 1 s; a 3 s fade may land at 3 or 4 s.
  Acceptable; if it bothers anyone, switch to `S.busy_frame_count`
  equivalent without changing the spec.
- **Separator row steals 1 row of transcript space.** `alt_screen`
  users lose 1 visible row on narrow terminals; acceptable, the
  separator is the point of the change.
- **Fade timers reset on resize** because `S` fields survive but
  `os.time()` is wall clock — no issue, flag can re-arm.
- **Spec change to `↓ +N`** breaks any test that hard-codes
  `новые`. Tests updated in the same change.

## Migration Plan

1. Land in one commit; update tests that assert the old status-line
   parts.
2. No user migration: existing config keeps working; `mouse`/`kb`
   flags simply appear less often. Rollback = revert the commit.
