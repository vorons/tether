# Proposal

## Why

Four TUI bugs in `src/tether/ui.lua` break input and error handling:

1. **Scroll inserts history.** When the input field is empty, Up/Down
   act as history navigation. Scrolling the transcript (the intended
   use of Up/Down when input is empty) therefore inserts a history
   entry into the input.
2. **Arrows only surface the last entry.** `history_prev`/`history_next`
   step a single `history_pos` index but `load_history` deduplicates
   consecutive entries, so navigating only ever reveals the most
   recent text.
3. **History pollution.** `session.add_history` is called for any
   non-empty typed line, even when the agent was never started —
   `history.jsonl` accumulates noise that later pollutes the Up/Down
   recall list.
4. **Error blocks submit.** While the error overlay is open,
   `handle_key` early-returns, so no message can be sent until the
   overlay is dismissed.

## What Changes

- **Up/Down when input is empty** SHALL scroll the transcript (with
  a follow-mode anchor when at the bottom) instead of navigating
  history. History navigation moves to an explicit key (Up/Down with
  a non-empty input, or a new `Ctrl+Up`/`Ctrl+Down`).
- **History recall order** SHALL walk the full deduplicated list,
  most-recent first, one entry per press, continuing past the first
  entry.
- **History recording** SHALL only happen when a message is actually
  committed to the agent (`commit_input` path); typed-then-discarded
  text is not recorded.
- **Error overlay** SHALL be dismissed by Enter/Esc (clearing
  `S.overlay`), after which input works; while open, the overlay is
  modal but does not permanently block submit.
- **BREAKING**: Up/Down semantics in the TUI change from
  "history-when-empty" to "scroll". Users who relied on Up to recall
  the last prompt while the input was empty now use Up with existing
  text, or the new explicit history key.

## Capabilities

### Modified Capabilities
- `tui`: input field / history / error-overlay requirements change
  (the spec was just archived from `archive-existing-behavior`; the
  deltas below replace those requirements).

### New Capabilities
- (none)

## Impact

- `src/tether/ui.lua`: `handle_key` (up/down/enter), `history_prev`,
  `history_next`, `load_history`, `commit_input`, `push_history`,
  `handle_agent_event` (`error` branch), `handle_overlay_key`.
- `src/tether/session.lua`: `add_history` call sites — verify only
  `commit_input` invokes it.
- `tests/lua_tests.lua`: T8/T9 (history), new cases for scroll-vs-
  history and error-overlay dismissal.
- `openspec/specs/tui/spec.md` (main spec): requirement updates on
  archive.
