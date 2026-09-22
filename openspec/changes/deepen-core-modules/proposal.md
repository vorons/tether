# Proposal

## Why

`ui.lua` (4616 lines, ~70 exports, one god-state `S`) absorbs two-thirds of recent commits: presentation, terminal protocol, slash commands, and session lifecycle share a single file, so bugs have no home and tests poke upvalues instead of module interfaces. `agent.lua` repeats the mistake for confirmation policy, while `retry.lua` proves the opposite shape (pure policy, 1 commit / 50) works.

## What Changes

- Extract a deep **`transcript`** module (embedded global): canonical events / seed / clear in, viewport rows out; absorbs `handle_agent_event`, row cache, stale-attempt drop.
- Keep terminal input decode in `ui.lua` for now (2A); no C-side parser (per `docs/decisions/2026-09-17-input-model.md`).
- Extract pure **`confirm_policy`** from `agent.lua` (`should_confirm`, `approve_key`, `check_auto_approve`) — same load/embed pattern as `retry`.
- Extract **`commands`** owning resume / new / compact / model: kills app↔ui resume duplication, fixes `-r` transcript-seed drift (already required by `tui` spec), returns `session_id` so `cfg` stops being a service locator.
- Extract **`turn`** control facade over `agent` (`start` / `confirm` / `answer` / `abort`): single owner of busy/waiting/streaming reset and abort seam; UI stops writing `agent.abort_requested`.
- Each new module = +1 row in `Makefile` `LUA_MODS`, embed-args, `main.c mods[]`.
- External agent contract unchanged: `turn` / `confirm` / `answer_ask` / `continue` + canonical events.

## Capabilities

### New Capabilities

_None — pure module-structure refactor._

### Modified Capabilities

_None — no spec-level requirement changes; `-r` transcript seeding is already required by `tui` and is fixed to match existing specs._

## Impact

- **Code:** `src/tether/ui.lua`, `src/tether/agent.lua`, `src/tether/app.lua`; new `src/tether/transcript.lua`, `src/tether/confirm_policy.lua`, `src/tether/commands.lua`, `src/tether/turn.lua`.
- **Build:** `Makefile` (`LUA_MODS`, embed list, `luac -p`), `src/host/main.c` (`mods[]`), generated `src/host/embed.c`.
- **Tests:** `tests/lua_tests.lua` (~248 `ui.*` references, `debug.getupvalue` seams retarget to new module interfaces).
- **Docs:** `CONTEXT.md` glossary (already drafted); no user-facing behavior change beyond fixing `-r` seed drift.
