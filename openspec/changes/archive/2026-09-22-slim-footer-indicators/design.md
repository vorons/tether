# Design

## Context

See proposal.md - Why. Layout is bottom-up (`reserve = 1 + shown_in + pal_h + 1 + 2 + flags_h`, `src/tether/ui.lua` `layout()`); `flags_h` currently pads 2 extra rows for the flags, producing a 3-row footer while indicators are active. In-transcript `↓ +N` marker is painted near the prompt row; mouse/keyboard mode icons live in `static_flags()`.

## Goals / Non-Goals

**Goals:**
- One footer row always; transcript gains the 2 rows previously reserved by `flags_h`.
- Scroll indicator only on that footer row; no in-transcript marker.
- Drop `🖱`/`⌨` icons; keep toast + scroll flag as transient right-side footer content.

**Non-Goals:**
- No change to input box, palette, header, or confirmation tails.
- No new config keys; no change to token/context math or ASCII rules.

## Decisions

- **Footer composition (left→right):** path (`$HOME`→`~`) + stats (`↑N ↓N context`) + transient flags (toast, `↓ +N`), model right-aligned with ≥2 col gap. Alternative (flags before stats) rejected: stats are session-stable, flags transient — placing flags last makes expiry/truncation simpler.
- **`flags_h` → constant 1:** `reserve` drops the elastic `+ 2`; `flags_row` collapses onto the single footer row (`footer_row + 1`). Alternative (keep `flags_h` as 0/1 and shift stats) rejected: two code paths for row math; constant height keeps `layout()` trivial.
- **Truncation order when over width:** model left-truncate → drop model → path right-truncate with `...` → drop toast → drop scroll flag → stats right-truncate with `...` last. Rationale: model tail and path identity are highest value; toast is one-shot; scroll flag is recoverable by scrolling.
- **Remove marker paint** (~2221-2228): only `scroll_flag()` output feeds the footer. ASCII `v +N` unchanged (already in `scroll_flag`).
- **Mouse/keyboard flags:** remove from `static_flags()`; leave `mouse_update_tracking()` tracking logic (still needed for behavior), only stop emitting `🖱`/`⌨`. Toast arming/clearing (~4021/~3905) unchanged.

## Risks / Trade-offs

- [Users relied on in-transcript marker for scroll position] → Footer `↓ +N` remains; behavior identical, only paint location changes. Acceptance T65 updates.
- [Narrow terminals hide more (model/toast) than before] → Defined truncation order; model was already right-aligned with drop path.
- [Session totals grow; footer left side may truncate earlier] → Same compact counters; path truncates before stats.

## Migration Plan

Single-commit UI change; no data migration. Rollback = revert commit. Living docs (README, tech-spec L47, design.md §6.13) updated in the same change.

## Open Questions

None.
