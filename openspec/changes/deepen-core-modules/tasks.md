# Tasks

## 1. Cut 1 — transcript module

- [x] 1.1 Create `src/tether/transcript.lua` with `handle(event)`, `seed(messages)`, `clear()`, viewport query; move row cache / stale-attempt drop out of `ui.lua` — verify `luac -p src/tether/transcript.lua`
- [x] 1.2 Wire embed: add row to `Makefile` `LUA_MODS`, embed-args, `luac -p` test target, and `main.c mods[]` (`transcript_lua` / `"transcript"`) — verify `make tether` links
- [x] 1.3 Point `ui` event reducer and resume `/resume` seed at the `transcript` global; drop transcript fields from god-state `S` — verify `make test` green
- [x] 1.4 Retarget transcript tests from `M._handle_agent_event` / upvalue pokes to `transcript.*` — verify transcript test block passes without `debug.getupvalue` on `ui.run`
- [x] 1.5 One logical commit for cut 1 — verify `git log -1` and full `make test`

## 2. Cut 2 — input contract (2A, no new global)

- [x] 2.1 Give `read_key` / `decode_*` a narrow bytes→events contract (typed `{kind=…}` events only; no layout or mode knowledge) — verify existing input/CSI tests still pass
- [x] 2.2 Route `handle_key` to consume only those events — verify `make test` green and no new exports required for input tests

## 3. Cut 3 — confirm_policy module

- [ ] 3.1 Create `src/tether/confirm_policy.lua` with `should_confirm`, `approve_key`, `check_auto_approve` (pure data-in/verdict-out; no I/O) — verify `luac -p`
- [ ] 3.2 Wire embed (`Makefile` + `main.c mods[]`) and load from `agent` via `_G.confirm_policy or loadfile(...)` — verify `make tether`
- [ ] 3.3 Replace in-file copies in `agent.lua`; keep projection / persist in `agent` — verify confirm-related tests pass against `confirm_policy` directly
- [ ] 3.4 One logical commit for cut 3 — verify `make test` green

## 4. Cut 4 — commands module (session lifecycle + slash side effects)

- [ ] 4.1 Create `src/tether/commands.lua`: `resume(id?)`, `new()`, `compact()`, model-list helpers; return `session_id` — verify `luac -p`
- [ ] 4.2 Wire embed (`Makefile` + `main.c mods[]`) — verify `make tether`
- [ ] 4.3 Point `app -r` and `ui /resume` / `/new` / `/compact` / `/model` at `commands.*`; write `cfg._session_id` at call sites only — verify `-r` startup seeds transcript (tui spec scenario) and `/resume` replaces it
- [ ] 4.4 Deduplicate resume/new between `app.lua` and `ui.lua`; seed via `transcript.seed` — verify both paths share one implementation and `make test` green
- [ ] 4.5 Retarget slash/session tests to `commands.*` — verify no `ui` key-handler test needs `agent.history` reach-in
- [ ] 4.6 One logical commit for cut 4 — verify `make test` green

## 5. Cut 5 — turn facade

- [ ] 5.1 Create `src/tether/turn.lua`: `start` / `confirm` / `answer` / `abort`; own busy/waiting/streaming reset; move `take_abort` / `ack_abort` seam — verify `luac -p`
- [ ] 5.2 Wire embed (`Makefile` + `main.c mods[]`) — verify `make tether`
- [ ] 5.3 Point UI commit/resolve paths at `turn.*`; remove `agent.abort_requested =` writes from `ui` — verify Ctrl+C abort still ends the turn and next turn is not pre-aborted
- [ ] 5.4 Keep `agent.turn` / `agent.confirm` / `agent.answer_ask` / `agent.continue` for print mode — verify `--print` path still calls `agent.turn` and exits 0/1 per spec
- [ ] 5.5 One logical commit for cut 5 — verify `make test` green

## 6. Final verification

- [ ] 6.1 Run full `make test` (luac + lua_tests + context_tests) — verify all green
- [ ] 6.2 Confirm `CONTEXT.md` architecture notes match landed cuts — verify glossary lists `transcript`, `commands`, `turn`, `confirm_policy` and cut order
- [ ] 6.3 Smoke: TUI start, one tool confirm, `/resume`, `-r` startup — verify no regression in transcript restore or confirmation menu
