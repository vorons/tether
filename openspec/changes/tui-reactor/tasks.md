# Tasks

## 1. Host step API (additive, no Lua behavior change)

- [x] 1.1 Expose `http_start`, `http_step`, `http_lines`, `http_fds`, `http_abort`, `http_free` in `src/host/main.c` factored out of `stream_perform` and verify `host_primitives_test.c` covers the start/step/lines/abort lifecycle
- [x] 1.2 Reimplement `http_stream` over the step API and verify the full `lua tests/lua_tests.lua` suite passes unchanged
- [x] 1.3 Make `read_char_nb` a pure non-blocking drain (drop the 50 ms wait — `select` runs with a zero timeout) and verify no test relies on its wait

## 2. Reactor loop

- [x] 2.1 Implement the Lua reactor (poll stdin + transport fds + deadline, readiness order input > transport > timers, 80 ms quantum) and verify scripted-readiness determinism test passes (same script, same dispatch order, no wall-clock)
- [x] 2.2 Move `ui.run` main loop onto the reactor loop (`on_stdin`/`on_tick` handlers driven by `loop:run()`) and verify TW1/TW2/TW3 plus the fragmented-sequence repro stay green
- [x] 2.3 Retire `pump_busy_hook` / `__tether_spinner_tick` globals and verify `rg` finds no references outside changelog/docs

## 3. Reactor-resident agent path

- [x] 3.1 Make `api.stream` incremental behind its signature (stepped transfer + per-tick SSE parse, identical event order) and verify differential test: recorded body through steps equals `http_stream` line sequence
- [x] 3.2 Convert retry/backoff waits to reactor deadlines preserving abort-on-`0x03` and closed-stdin semantics and verify retry/backoff tests pass
- [x] 3.3 Verify print mode still uses blocking `http_stream`/`http_get` and `sh tests/host_smoke.sh` passes

## 4. Acceptance

- [x] 4.1 Verify mid-turn wheel scroll applies and repaints within one tick with no stream events and no input leak (fragmented-sequence scenario from specs/reactor)
- [x] 4.2 Run `make test` fully green except the pre-existing T187 device-flow failures unrelated to this change
