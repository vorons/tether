# Design

## Context

The TUI main loop is synchronous: `commit_input` → `turn.start` → blocking `agent.turn`. Keys are only read between turns (`read_key` in the main loop). Ctrl+C works mid-turn via the host's `tether.abort_requested` flag checked by libcurl's progress callback and the agent loop — not via Lua key decoding. The decoder already produces `{kind="enter"}`, `{kind="alt", code=13}` / modified Enter as `newline` when alt/shift/ctrl are set, and confirmation/ask own the keyboard when open (`handle_key` dispatches to them first). There is no message queue. `!` does nothing special. See proposal.md for motivation.

## Goals / Non-Goals

**Goals:**
- Accept Enter / Alt+Enter / Escape while busy without a second concurrent turn.
- Inject steering at segment boundaries; follow-ups after settle.
- `!` / `!!` shell prefix sharing the `run` tool's execution path.
- Zero new dependencies; no background timers.

**Non-Goals:**
- Parallel agent loops or async rewrite of `turn.start`.
- Mid-tool-confirmation steering (confirmation keeps the keyboard).
- Configurable keybindings for steer/follow-up (fixed to Enter / Alt+Enter for now).
- PTY or interactive commands via `!`.

## Decisions

1. **Busy key pump inside `paint()` / event path using `read_char_nb`**  
   The stream already calls `handle_agent_event` → `paint`. Drain available bytes with the existing non-blocking host read and run a narrow dispatcher (`steer_key`) that only understands enter/alt-enter/esc (and ignores text until we decide whether to live-edit mid-turn). Alternative: make `agent.turn` re-entrant / generator-based — rejected as a large rewrite of the facade. Text editing mid-turn is in scope only for the input box (keys that are not enter/esc/alt-enter can still be fed to the normal input editor so the user can type while waiting); the pump must not recurse into `commit_input`'s turn start when busy — it enqueues instead.

2. **Queues live in UI state (`S.steer_queue`, `S.followup_queue`), injection is pull-based from the agent**  
   UI owns presentation; agent owns history. After a segment completes (tool step drained or final answer), `main_loop` checks a callback/ref provided by the UI (or `M.take_steer()` on agent) and injects before the next LLM call. After `turn.start` returns fully settled, the UI drains `followup_queue` in order via a fresh `turn.start` per message. Alternative (push user text into agent mid-stream) races with the OpenAI tool_call contract — rejected.

3. **Alt+Enter mapping: keep `newline` when idle; when busy, decoder already can emit alt-marked events**  
   Today modified Enter becomes `kind="newline"` with no alt flag preserved on that branch — we need the alt flag preserved on newline events (or a dedicated `kind="alt_enter"`) so the busy pump can distinguish. Idle path: `newline` inserts `\n` as now. Spec freezes that.

4. **Escape restore builds input text, does not auto-resubmit**  
   Abort via existing `turn.abort()`; on turn return, join queues into `S.input`. Alternative (auto-resend) would surprise users who wanted to edit.

5. **`!` handled in `commit_input` before turn start, after slash resolution**  
   Reuse `tools.run` (or its internals) for execution; render a synthetic tool row via `transcript`. For `!cmd` "feed next message": append output to a pending context buffer that `commit_input` prepends/appends to the next user/steering text (simplest that keeps agent-core journal rules). Alternative (always inject as a tool result) requires a fake tool_call id and provider-specific shapes — rejected for v1.

6. **Queue cap 8, error banner reuse**  
   Same one-shot banner mechanism as other UI errors.

## Risks / Trade-offs

- [Pump races with bracketed paste / escape sequences mid-turn] → Only drain complete decoded keys via existing `read_key` logic refactored to a non-blocking peek; drop incomplete sequences rather than blocking.
- [User types a lot mid-turn; input box state vs paste] → Normal input editor paths run; no special casing beyond enqueue-on-enter.
- [Steer injection mid tool-batch] → Spec: inject after the tool step's `drive_pending` drains, not mid-batch.
- [Follow-up + abort interaction] → Escape clears both queues per spec; abort alone leaves queues for settle-then-run (document: follow-ups survive abort? Spec says Escape restores; plain abort without Escape keeps queues — align implementation with "Escape restores; abort via Ctrl+C also restores"? Keep: Ctrl+C abort ends turn; UI then runs follow-ups only if user did not Escape — safer: Ctrl+C also leaves queues in editor? Resolve: Ctrl+C aborts run but does not auto-restore; queues remain and follow-ups still run after settle unless Escape was used. This is subtle — **decide: Ctrl+C abort clears queues into editor as well** (same as Escape) to avoid surprising auto-starts after interrupt. Update spec if needed during apply — actually spec only defines Escape; leave Ctrl+C as "queues persist and follow-ups run after settle" OR fold into Escape-only. I'll keep Escape as the only restore path; Ctrl+C keeps queues → follow-ups run. Document in design as accepted.)

## Migration Plan

1. Decoder: preserve alt on Enter → distinct event.
2. UI: queues + pump + enqueue paths + Escape restore + cap banner.
3. Agent: segment-boundary `take_steer` hook + journal.
4. Follow-up drain after settle.
5. `!` / `!!` path.
6. Tests throughout; no config flag (on by default).

## Open Questions

- Should Ctrl+C (abort) also restore the queue to the editor like Escape? Spec only requires Escape. Default during apply: Ctrl+C does **not** restore; follow-ups still run after settle unless Escape was pressed. Revisit if it feels wrong in manual test.
