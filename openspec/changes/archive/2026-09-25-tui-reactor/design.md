# Design

## Context

Today the loop belongs to C: `stream_perform` (`src/host/main.c`) runs curl
multi with an 80 ms quantum and fires Lua only through callbacks
(`http_xferinfo` → spinner tick, write callback → `on_event`). `turn.start`
blocks inside `pcall(agent.turn)` for the whole turn, and the TUI main loop
(`ui.run`) is parked meanwhile. Input reaches Lua through two narrow pipes:
`poll_interrupt` queueing stdin bytes during transfers, and `pump_keys` on
stream events. See proposal.md Why. Constraints: one `lua_State` (no threads
touching Lua), raw-mode terminal, vendor'd curl/mbedTLS, canonical agent
events unchanged (`openspec/specs/agent-core`).

## Goals / Non-Goals

- Goals: one tick quantum (80 ms) bounds key-to-effect latency mid-turn;
  zero stdin blocking inside any transfer/timer callback; print mode and all
  one-shot `http_stream` callers keep working unchanged.
- Non-Goals: multi-threading; changing the canonical event set; changing CLI
  surface; touching provider adapters (they consume lines either way).

## Decisions

- **Lua owns the poll, C owns the fds.** C exposes `http_start`, `http_step`,
  `http_lines`, `http_fds`, `http_abort`, `http_free` plus a generic
  `poll(read_fds, write_fds, timeout)` helper; Lua's reactor loop computes
  readiness and dispatches. Why: keeps all policy
  (throttle, caret, scroll pin) in Lua where it already lives; C stays a thin
  fd/step surface. Alternative (C-owned loop with more Lua hooks) rejected:
  it preserves the exact callback-blocking class of bugs we are removing.
- **Step API mirrors `stream_perform` internals.** `stream_perform` already
  does multi + `curl_multi_poll` + `poll_interrupt`; the step version is that
  body with stdin removed, one quantum per call. `http_stream` is reimplemented
  on top of steps (loop until done) so wire behavior cannot diverge; print
  mode is unaffected.
- **`api.stream` becomes incremental behind the same signature.** It opens a
  stepped transfer and yields lines to the existing SSE parser per reactor
  tick, emitting the identical event sequence. Retry/backoff sleeps become
  reactor deadlines; `interruptible_sleep`'s `pump_busy_hook` is subsumed by
  the loop and retired. Alternative (agent in a forked child) rejected:
  doubles Lua state and needs an IPC event protocol for marginal gain.
- **`ui.run` becomes tick callbacks.** The blocking `read_key` loop turns into
  the reactor loop: `loop:on_stdin` / `loop:on_tick` handlers dispatched by
  `loop:run()` on an 80 ms quantum; `pump_keys` and the ESC-fragment stash
  become loop mechanics. `__tether_spinner_tick`/`pump_busy_hook` globals die.
- **`read_char_nb` goes pure non-blocking.** The 50 ms wait is gone: the
  primitive's `select` runs with a zero timeout, and readiness waiting lives
  in the reactor poll (`tether.poll`). Callers that relied on the wait (busy
  pump's drain loop) now rely on tick readiness instead.

## Risks / Trade-offs

- [Risk] Step/timeout edge cases diverge from `http_stream` (idle timeout,
  abort mid-header) → Mitigation: `http_stream` reimplemented over steps;
  differential test feeds identical recorded bodies through both paths.
- [Risk] Reactor tick starves under delta floods → Mitigation: keep the
  existing delta-throttle; readiness order is input > transport > timers, so
  keys always win a tick.
- [Risk] `l_exec` (tool run) still blocks up to its quantum slices with
  `nanosleep` → Accepted: it already ticks the spinner and checks abort;
  later it can become a reactor child-watch without spec changes.
- [Risk] Large diff across host/api/agent/ui → Mitigation: land C step API +
  `http_stream`-over-steps first (no Lua behavior change), then reactor loop,
  then retire hooks; each step keeps the suite green.

## Migration Plan

1. Add step API; reimplement `http_stream` over it; suite green, no Lua changes.
2. Add reactor; move `ui.run` loop onto it; retire pump/spinner globals.
3. Make `api.stream`/backoff reactor-resident; print mode stays on blocking calls.
4. Rollback per step: each is independently revertible (step API is additive).

## Open Questions

- None blocking. Quantum stays 80 ms (pi's Loader cadence, already in spec
  use); child-process watch for `l_exec` is future work, not this change.
