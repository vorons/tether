# Proposal

## Why

The TUI and the agent share one OS thread: while a turn runs, `stream_perform`
owns the loop in C and Lua only sees callbacks. Input is drained only on
stream events or 80 ms spinner quanta, so wheel scroll lags a step behind and
fragmented escape sequences leak into the input (`[<65;48;31M`). Patching the
pump wider treats symptoms; the loop itself must stop belonging to the transfer.

## What Changes

- New `reactor` capability: a single-threaded, Lua-owned event loop. One
  `poll` over stdin + curl sockets + timers drives input, streaming, spinner,
  backoff and resize. No callbacks that block on stdin; no 50 ms `select`
  inside transfer callbacks.
- The vendor transport gains an incremental step API alongside `http_stream`
  (which stays for print mode and one-shot callers): start transfer, poll
  fds, step with timeout, drain lines, abort, free.
- `tui` main loop becomes a tick handler on the reactor: input is always live,
  including mid-turn; the key pump and fragmented-sequence handling move from
  advisory callbacks into the loop invariant.
- **BREAKING** (internal only, no CLI change): `tether.sleep` no longer needs
  its wake-on-input contract for the TUI path — the reactor owns waiting.
  `pump_busy_hook` / `__tether_spinner_tick` globals are retired once the
  reactor lands.

## Capabilities

### New Capabilities

- `reactor`: Lua-owned single-threaded event loop over stdin, transport
  sockets and timers; readiness, deadlines, and dispatch order guarantees.

### Modified Capabilities

- `host`: new non-blocking transport-step primitives; loop ownership moves
  from C callbacks to Lua; `read_char_nb` becomes a pure non-blocking drain.
- `vendor-transport`: incremental transfer API (`start/poll/step/drain/abort`);
  `http_stream`/`http_get` behavior unchanged.
- `tui`: input stays live mid-turn by construction; the "no background timer"
  repaint rule is replaced by reactor ticks; scroll/keys apply within one
  tick, never queue until the next model/tool event.

## Impact

- `src/host/main.c`: new `tether.http_*` step functions, fd exposure for
  `poll`, removal of in-callback stdin `select` and spinner-tick reentrancy
  guards where the reactor subsumes them.
- `src/tether/api.lua`, `agent.lua`: streaming and backoff become
  reactor-resident (incremental), keeping the canonical event set unchanged.
- `src/tether/ui.lua`: main loop becomes `reactor.run` tick callbacks;
  `pump_keys`/fragment stash become loop mechanics, not best-effort hooks.
- Tests: `tests/lua_tests.lua` gains reactor determinism tests (scripted
  fd readiness); `host_primitives_test.c` covers the step API.
