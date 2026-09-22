# Design

## Context

See proposal.md — Why. Constraints that shape the approach:

- Single binary: no filesystem for Lua at runtime; every module is embedded via `tools/embed.lua` → `embed.c` and registered as a global in `main.c mods[]` (precedent: `providers/*` → `provider_openai`).
- Test harness loads modules with `loadfile` + `package.preload` and currently reaches into `ui` via ~248 `ui.*` references and `debug.getupvalue`.
- External agent contract (`openspec/specs/agent-core`): `turn` / `confirm` / `answer_ask` / `continue` + canonical `on_event` stream — must not change.
- `docs/decisions/2026-09-17-input-model.md`: C-side SGR/mouse parser stays ruled out; input decode remains in Lua.
- Domain glossary lives in `CONTEXT.md`.

## Goals / Non-Goals

**Goals:**

- Vertical deep modules with narrow interfaces; `ui.run()` and the agent-core contract stay the only stable outer entry points.
- Incremental cuts: each cut leaves the binary green (`make test`) and is independently revertible.
- Locality for the hottest bug clusters: transcript reducer, confirm policy, session lifecycle, abort/busy state.

**Non-Goals:**

- No big-bang rewrite of `ui.lua`.
- No C-side input parser; no moving decode to `main.c`.
- No extraction of projection / auto-approve persistence (I/O stays in `agent`).
- No change to canonical event shapes, provider adapters, or retry policy.
- No `input` embedded global in the first pass (stays inside `ui.lua` until the split pattern is proven).

## Decisions

### D1 — Strategy: incremental cuts, separate embedded globals (A + A1)

Alternatives: big-bang five-module split; build-time concatenation into one `ui.lua`; internal-only sections with no file split.

Chosen: one new global per cut, same registration path as `retry` / `ask` / `diff`. Rationale: deletion test concentrates complexity per module; embed cost is one Makefile row + one `mods[]` row; big-bang risks a long red cycle across 248 test references.

### D2 — Cut order

`transcript` → input (2A, no new global) → `confirm_policy` → `commands` → `turn`.

Rationale: transcript is already half-isolated (row cache) and feeds the hottest reducer bugs; input pays off fully only after modal state is clarified, so 2A keeps decode beside dispatch for now; confirm follows the proven `retry` pattern; `commands` must precede `turn` so `/compact` no longer reach-ins to `agent.history` before the facade owns control flow.

### D3 — `transcript` module shape

- Embedded global name: `transcript` (domain term from design.md / CONTEXT.md, precedent `diff` / `ask` / `retry` — not `ui_*`).
- Interface (data-in / rows-out): `handle(event)` | `seed(messages)` | `clear()` | viewport query (rows, `↑ N more`, pending-confirm indicator).
- Absorbs: the row-mutation half of `handle_agent_event` (via `handle(event)`), row cache / prefix-index / LRU, stale-attempt / retry-row drop.
- Stays in `ui`: the reducer shell around `transcript.handle` — input, palette, overlay/confirm/ask **mode** (keyboard ownership), busy/streaming flags, layout/paint.
- `seed` is wired once in `ui.run()` startup (clear → seed from `agent.get_history()`); `/resume` re-seeds through `transcript.seed`. `app -r` only restores agent history via `commands.resume` — seeding stays out of `app` (fixes drift already required by `tui` “Transcript restore on resume”).

Alternatives: seed both call sites in cut-1 (couples to commands early); leave app unwired forever (locality fails).

### D4 — Input stays in `ui` (2A)

Decode functions (`read_key`, `decode_*`) get a narrow internal contract (bytes → typed events) but no separate global until `transcript` proves the split. Keeps `handle_key` and decode co-located with modal dispatch; respects the input-model decision.

### D5 — `confirm_policy` as pure policy

- Global `confirm_policy`: `should_confirm`, `approve_key`, `check_auto_approve` (+ session-approve lookup if trivial).
- Load pattern: `_G.confirm_policy or loadfile("src/tether/confirm_policy.lua")` inside `agent`, same as `retry`.
- `projection_for` and `persist_auto_approve` remain in `agent` (file I/O).
- External confirm decision strings (`allow` / `session` / `always` / `deny` / `cancel`) unchanged.

### D6 — `commands` single owner of session lifecycle

- Global `commands`: `resume(id?)`, `new()`, `compact()`, `list_models()` / live model list, plus the slash-command dispatch UI currently performs in `execute_command`.
- Returns `session_id`; caller (`app` or `ui`) writes `cfg._session_id` — cfg is no longer a service locator.
- Both `app -r` and `ui /resume` call `commands.resume`; the visible transcript is seeded through `transcript.seed` (`ui.run()` startup for `-r`, direct call for `/resume` — drift fix).
- UI only renders results; no direct `agent.history` mutation, no sync HTTP inside key handlers beyond what `commands` encapsulates (model list remains blocking for now — async model picker is out of scope).

### D7 — `turn` control facade

- Global `turn`: `start(text)` | `confirm(id, decision)` | `answer(id, payload)` | `abort()`.
- Owns busy/waiting/streaming reset (single place) and abort seam: `take_abort` / `ack_abort` move here; UI calls `turn.abort()`, never assigns `agent.abort_requested`.
- Events remain on `agent`'s `on_event` (facade passes the callback through).
- `agent`'s four entry points stay for non-UI callers (print mode uses `agent.turn` directly).

### D8 — Test migration

- Pure ui exports (wrap, fuzzy, md, sanitize) stay on `ui` until a later layout cut — not part of this change.
- Row-only transcript tests use `transcript.*` direct calls (via `ui._transcript`); mode/paint tests keep `M._handle_agent_event` (the ui reducer shell). No `debug.getupvalue` on `ui.run` remains — state via `M._get_state`.
- `confirm_policy` tests are pure table tests (retry-style).
- `commands` / `turn` tests use stub globals via existing `host_mock` / preload harness.

## Risks / Trade-offs

- [Embedded global count grows (+4)] → Mitigation: same pattern as providers; one `mods[]` row each; revisit consolidation only if embed list becomes unwieldy.
- [Mid-cut `S` shared across `ui` and `transcript`] → Mitigation: cut-1 moves transcript fields wholesale; no dual ownership of row cache.
- [248 `ui.*` test references break gradually] → Mitigation: keep pure exports on `ui`; only transcript/confirm paths move; `make test` green per cut.
- [Facade duplicates agent entry points] → Mitigation: `turn` is thin orchestration only; no second copy of the loop.
- [`commands` grows into god-module] → Mitigation: only session lifecycle + slash side effects; palette/render stays in `ui`.

## Migration Plan

Per cut: extract → wire embed/Makefile/`mods[]` → retarget tests → `make test` green → next cut. Rollback = revert the cut commit (each cut is one logical commit).

## Open Questions

- Whether `input` is promoted to its own global after cut-1 — deferred until the `transcript` split is proven in practice.
- Async `/model` list fetch — deferred; out of scope for `commands`.
