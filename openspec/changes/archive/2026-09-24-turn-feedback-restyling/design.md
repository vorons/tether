# Design

## Context

See proposal.md (Why). Current state (observed):
- `render_entry` paints a `✻ tether думает…` row for the synthetic `placeholder` tail while `S.waiting`; `render_transcript` appends a spinner glyph to the live tail; the input box top rule carries spinner + elapsed.
- Thinking rows render `✻ thinking ▾` with no elapsed; entries carry no timestamps.
- Assistant rows use the `● ` prefix (literal, leaks through ASCII mode).
- Spinner frames advance per repaint; the main loop is key/event-driven (no timer) — animation exists only while the turn produces repaints.

## Goals / Non-Goals

- Goals: busy feedback consolidated in the input box; transcript free of placeholder rows; elapsed thinking rows; lighter assistant marker.
- Non-Goals: caret behavior; retry/backoff indicator; top-rule status; confirmation/ask/login flows; background-timer animation (spinner still advances on repaints only).

## Decisions

1. **Top-rule status owns the busy state.** `turn_status()` returns only the live spinner frame plus `Working...` while `S.busy` (retry/backoff leg unchanged). Rationale: single obvious place; the input box stays usable and untouched.
2. **Remove the placeholder tail, keep the flag.** `transcript` drops `placeholder_entry` (third tail); `sync_tail` no longer takes a waiting leg; `S.waiting` transitions stay (tests and tail logic reference the flag, rows are gone). render_entry's placeholder branch and the live-tail spinner append are deleted. Rationale: row-level removal kills all placeholder assertions at the source; flag retention keeps the diff small.
3. **Thinking elapsed via `started_at`.** `transcript.handle` stamps `started_at = os.time()` when a thinking entry is created (not per delta, else elapsed resets); render prints `think · %.1fs` reusing the pending-tool convention (integer seconds render as `N.0s`). Collapsed one-liner keeps the toggle hint.
4. **Assistant marker `·` with ASCII twin.** Prefix selected by the same ascii branch as list bullets (`·` vs `-`); add `·`→`-` to GLYPH_MAP so `to_ascii` paths stay pure ASCII.

## Risks / Trade-offs

- [Risk] Placeholder-lifecycle tests (T54/T88/T90/T124/T125/T129, pi 4.1) assert removed behavior → Mitigation: rework each to the new specified behavior in the same change (no silent deletions).
- [Risk] ui.lua main-chunk 200-locals limit → Mitigation: helpers as `M.*` fields, zero new chunk locals.
- [Risk] Spinner frozen during token-less waits (no repaints) → Accepted explicitly: indicator appears only while the turn runs; animation follows repaints as specced.

## Migration Plan

Single release, no flag. Rollback: revert the render commits; no data migration involved.

## Open Questions

None.
