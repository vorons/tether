# Proposal

## Why

While the agent is streaming, the UI blocks inside `turn.start` and the main loop never reads keys — the user cannot redirect work, queue a follow-up, or drop a draft without waiting for the turn to end. There is also no one-shot shell prefix, so quick commands like `git status` either become a full agent turn or leave the app.

## What Changes

- **Busy-time input**: while `S.busy`, the UI pumps non-blocking keys (inside the existing paint/event path) so Enter / modifier keys are handled mid-turn.
- **Enter = steer**: a message submitted while busy is queued as a *steering* message; when the current assistant segment finishes (after its tool-call step, before the next LLM call), it is injected as the next user message and guides that response. It is shown in the transcript immediately as a user row.
- **Alt+Enter = follow-up**: a message submitted while busy is queued as a *follow-up*; it runs only after the agent fully settles (no pending tools, no confirmation), as a fresh turn on the same history.
- **Escape while busy with a non-empty queue**: aborts the current run (existing `turn.abort` seam) and returns all queued messages to the editor, one per line, in submission order — nothing is lost.
- **Queue limits**: at most 8 queued messages; further submits while full show a one-shot error banner, not silent drops.
- **`!` shell prefix**: a committed input starting with `!` (after trim) runs the rest as a shell command in the workspace (`sh -c`, same sandbox as the `run` tool): output is captured and (a) `!cmd` — shown as a tool-style row and appended to the next user message context; (b) `!!cmd` — output is shown in the transcript only and **not** sent to the model. Neither form enters agent history as a user prompt.
- Slash-command resolution (`/…`) stays ahead of `!` handling; a literal `!` at start never opens the palette.

## Capabilities

### New Capabilities

- `steering`: busy-time key pump, steer vs follow-up queues, Escape restore, queue cap, and the injection boundaries in the agent loop.
- `shell-prefix`: `!` / `!!` commit path semantics and transcript rendering.

### Modified Capabilities

- `tui`: Enter behavior while busy; key pump integration; interaction with confirmation menus and ask blocks (those keep owning the keyboard — busy pump runs only when no confirmation/ask is parked).
- `agent-core`: accept injected user messages at the turn boundary (`steer`) and as a new turn after settle (`follow-up`) without corrupting the retry/continuation state; journal user messages on injection.

## Impact

- Code: `src/tether/ui.lua` (commit path, busy key pump, queue state), `src/tether/turn.lua` / `agent.lua` (boundary injection), `src/tether/transcript.lua` (queued-row rendering if needed), `src/tether/tools.lua` (shared shell runner for `!` — reuse `run` internals).
- Tests: unit tests for queue semantics and `!` parsing; integration-style tests driving `_handle_key` while a fake busy turn is active.
- No config keys required for the first cut (all behavior on by default); optional later: `ui.steering = true|false`.
- Keyboard: relies on existing kitty CSI-u / modifyOtherKeys alt detection (`k.alt` already in the decode contract); plain terminals without alt reporting degrade Alt+Enter to Enter (documented).
