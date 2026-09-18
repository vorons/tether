# Proposal

## Why

The input field and the status line render back-to-back with no visual
gap, so they bleed into each other on narrow terminals. The status line
also carries constant chrome (`🖱 auto`, `⌨ kitty`) that rarely changes
and adds noise. The footer needs a visual break and a leaner default.

## What Changes

- **New**: a dim `─`-filled separator row between the input field and
  the status line (F1b). Owned by `layout()` so `alt_screen`/input
  height changes keep it exact.
- **Compact status line (5b)**: the default status line shows exactly
  four mandatory parts — `spinner Ns` (only while a turn is busy),
  `model`, `workspace`, `token usage`. Mouse-mode and keyboard-protocol
  flags are shown only when relevant:
  - `🖱 <mode>` — visible for ~3 s after the mouse mode actually
    changes, then fades out.
  - `⌨ <proto>` — visible only when a protocol is detected (non-zero).
- **Scroll indicator** stays in the status line but uses a shorter
  label: `↓ +N` (ASCII `v +N`) instead of `↓ новые +N`. The
  in-transcript marker follows the same label.
- **Toast** (`✓ скопировано`) keeps its current one-shot placement: it
  leads the status line and is cleared by the next keypress. No change.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `tui`: status-line composition (mandatory parts, fade behavior for
  mouse/kb flags), separator row between input and status line, and
  the scroll-indicator label.

## Impact

- `src/tether/ui.lua` — `layout()` (one extra fixed row), `render_input`,
  `render_status` (5b composition, fade timers), scroll-indicator label.
- `openspec/specs/tui/spec.md` — delta for status line, scroll
  indicator, screen regions.
- No config schema change beyond a potential `ui.status_flags` toggle
  if we want the old behavior back (defer to design.md).
