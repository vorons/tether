# Proposal

## Why

Turn progress is split across two places: a `✻ tether думает…` placeholder row in the transcript plus a spinner on the input box's top rule, while the input box itself sits empty. The placeholder duplicates what the input box can carry, thinking rows show no elapsed time, and the assistant `●` marker is visually heavier than the rest of the transcript. Consolidating busy feedback into the input box frees the transcript for actions only.

## What Changes

- While a turn is running (`S.busy`), the input box's top rule status shows only the spinner frame plus `Working...` (spinner advances on repaints during the turn; no background timer — event/keypress-driven repaints as today).
- The transcript waiting placeholder (`✻ tether думает…` row) is removed; the transcript shows only real entries (user/assistant/thinking/tool/system rows) plus the existing streaming caret.
- Thinking rows render as `think · Ns` (live elapsed like pending tool rows) instead of `✻ thinking ▾`; the collapsed form stays a one-liner.
- Assistant rows use the `·` marker instead of `●` (ASCII mode: `-`, via the existing glyph map).
- Out of scope: caret behavior, retry/backoff indicator, confirmation/ask/login flows, any background-timer animation.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `tui`: "Live turn feedback" requirement — waiting state moves from the transcript placeholder row into the input box; placeholder scenarios replaced by input-box scenarios.

## Impact

- `src/tether/ui.lua`: `render_input` busy branch, placeholder branch of `render_entry` (and tail-sync handling), thinking header, assistant prefix, glyph map (`·`).
- `src/tether/transcript.lua`: thinking entries gain `started_at` for elapsed rendering.
- `tests/lua_tests.lua`: rework placeholder-lifecycle blocks (T54/T88/T90/T124/T125/T129, pi 4.1) to the new specified behavior.
- No provider/agent/session changes; no new dependencies.
