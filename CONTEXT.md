# tether — domain glossary

Terms used in architecture reviews, specs, and module names.

## Core concepts

- **transcript** — the visible conversation model: canonical agent events and
  session history reduced to display rows (scroll, attempt tags, confirmation
  tails). Embedded global `transcript`; owned by the deep module split out of
  `ui.lua`. Interface: event | seed | clear in, viewport rows out.
- **turn** — one user message through the agent loop until a parked
  confirmation/ask or completion (`agent.turn` / `agent.continue`).
- **canonical events** — provider-agnostic stream from `agent`
  (`text_delta`, `tool_call_*`, `confirmation`, `ask`, `retry`, `error`, …).
- **confirmation** — parked tool call awaiting allow/session/always/deny/cancel.
- **ask** — parked structured question batch; same parking path as confirmation.
- **session** — JSONL journal under `~/.tether/sessions/`; resume rebuilds
  agent history (and, when wired, seeds the transcript).
- **workspace** — realpath root; tools and confirm policy resolve paths against it.

## Architecture notes (review decisions, 2026-09-22)

- `ui` remains the facade entry (`ui.run()`); vertical splits register as
  separate embedded globals (pattern: `providers/*` → `provider_openai`).
  Each new global = +1 row in `Makefile` `LUA_MODS`, embed-args, `main.c mods[]`.
- Strategy for `ui.lua`: **incremental cuts**, not big bang (A + A1).
- **transcript** — cut-1: event/seed/clear in, viewport rows out; absorbs
  `handle_agent_event`, row cache, stale-attempt drop; `seed` interface exists,
  `app` wires it in the `commands` cut (fixes `-r` drift).
- **input** (candidate 2): stays inside `ui.lua` for now (2A); decode remains
  Lua per `docs/decisions/2026-09-17-input-model.md`; promote to its own
  embedded global only after `transcript` proves the split pattern.
- **confirm_policy** — first pure policy out of `agent.lua` (`should_confirm`,
  `approve_key`, `check_auto_approve`); `compression` second; projection and
  auto-approve persistence stay in `agent` (I/O).
- **commands** — one global owning resume/new/compact/model (kills app↔ui
  resume duplication, fixes drift); returns `session_id`, caller writes
  `cfg._session_id` (cfg stops being a service locator).
- **turn** — control facade over `agent` (`start`/`confirm`/`answer`/`abort`);
  owns busy/waiting/streaming reset and abort seam (`take_abort`/`ack_abort`);
  events stay on `agent`'s `on_event`. Cut order: after `commands`.
- **Cut order:** transcript → input(2A, optional) → confirm_policy → commands → turn.
- External agent contract unchanged throughout: `turn`/`confirm`/`answer_ask`/`continue`
  + canonical events (`openspec/specs/agent-core`).
