# Design

## Context

Four input/error bugs in the TUI. The current key model conflates
"scroll the transcript" and "walk input history" on Up/Down whenever
the input is empty, and `session.add_history` is invoked from a path
that fires on any typed line. The error banner is modal through the
generic overlay early-return in `handle_key`.

See `proposal.md` — Why.

## Goals / Non-Goals

Goals:
- Up/Down with empty input scrolls the transcript; history recall
  moves to an explicit key.
- History recall walks the full deduplicated list.
- Only committed-to-agent messages are recorded in history.
- Error overlay is dismissable and does not permanently block
  submit.

Non-goals:
- No new history persistence format (keep `history.jsonl`).
- No change to the agent loop, API client, or tool policy.
- No rework of the mouse/SGR path.

## Decisions

**D1 — Key map.** Up/Down:
- non-empty input → cursor move between input lines; at a cursor
  edge, scroll the transcript (existing behavior).
- empty input → scroll transcript (Up = up, Down = down + follow
  mode). **This replaces** the current `if S.input == "" then
  history_prev/history_next`.
- `Ctrl+Up` / `Ctrl+Down` → history recall / step forward. These
  bind via the existing `handle_ctrl` (codes 20/21 are Ctrl+U/Ctrl+T;
  we add Up/Down detection from the key reader when Ctrl is held —
  the Kitty/modifyOtherKeys protocols already deliver Ctrl+arrows).

Alternative considered: keep Up/Down dual-role and only fix the
"only last entry" bug. Rejected: the scroll-inserts-history symptom
is the conflation itself; a dual role that "sometimes scrolls,
sometimes recalls" is the root cause.

**D2 — History recall walks the list.** `S.history_pos` currently
starts at `#S.history + 1` (past-the-end sentinel). `history_prev`
does `-1` (lands on the most recent entry), `history_next` `+1`. The
"only last text" symptom comes from `load_history` dedup collapsing
the list to effectively one entry in many sessions, plus the
sentinel arithmetic. Fix: keep the sentinel model, but ensure
`load_history` dedup does not collapse the recall list to one entry
(dedupe only exact consecutive repeats, which it already does —
verify against the recorded-only-committed change in D3). Repeated
Ctrl+Up SHALL step through entries 5,4,3,2,1 (most-recent first),
wrapping at the oldest (stop at index 1). Ctrl+Down steps back
toward the sentinel; at the sentinel the input clears.

**D3 — Record only committed messages.** Move the
`session.add_history` call so it runs only inside `commit_input` on
the committed text (after the slash-command branch). Remove any
call site that records uncommitted typed text. `push_history`
(in-memory recall cache) is likewise only invoked on commit.
Verify no other caller records typed-then-discarded lines.

**D4 — Error overlay dismissal.** `handle_overlay_key` for the
`error` overlay SHALL map Esc **and** Enter to close: set
`S.overlay = nil`, `S.overlay_data = nil`. The banner
(`S.error_banner`) is intentionally kept so the user can re-open;
but submit (`commit_input`) already clears `S.error_banner`, so a
dismissed overlay returns to a working input. Remove the
`if S.overlay then handle_overlay_key(k); return end` early-return's
effect of swallowing Enter — Enter in the error overlay closes it
and then, on the *next* Enter, submits (the banner-clear happens in
`commit_input`). Net: dismiss → type → Enter sends.

Alternative considered: auto-clear the banner on any key.
Rejected: the user may want to re-read the full error.

## Risks / Trade-offs

- [Ctrl+arrows not delivered on terminals without Kitty/
  modifyOtherKeys] → fall back: if the key reader cannot produce
  Ctrl+Up/Ctrl+Down, bind history recall to `Ctrl+P`/`Ctrl+N`
  (common in shells) instead. Decide at implementation by checking
  which keys `read_key` actually yields on the user's terminals;
  ship the arrow version, keep `Ctrl+P`/`Ctrl+N` as the fallback.
- [Changing Up/Down breaks muscle memory] → note in README/help
  overlay that scroll is now Up/Down and history is Ctrl+Up/Down.
- [Dedup + record-only-committed may shrink the recall list]
  → acceptable: the contract is "recalled items are ones you
  actually sent".

## Open Questions

- Exact history-recall key: `Ctrl+Up/Ctrl+Down` vs `Ctrl+P/Ctrl+N`.
  Decide at implementation based on terminal key delivery; default to
  Ctrl+arrows with Ctrl+P/N as the recorded fallback.
