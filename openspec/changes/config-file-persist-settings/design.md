# Design

## Context

See proposal.md (Why). Current state (observed):
- `config.load(path, home)` deep-merges the user table over `default_config()`; a missing file loads defaults silently. Nothing in `src/` writes `config.lua`.
- `pick.model` (ui.lua) sets `S.model_name` / `S.cfg.model` / `S.cfg.provider` in memory only.
- Stopgap `~/.tether/model.lua` side file (`save_model`/`load_model`, T177) holds the last pick; `M.load` merges it below explicit config values.
- Only `provider` and `model` mutate at runtime; `api_key` resolves to `auth.json`/env and must never land in `config.lua`.

## Goals / Non-Goals

- Goals: `config.lua` created once with commented defaults; `/model` writes `provider`/`model` back into it preserving everything else; one-time `model.lua` migration; restart restores the pick.
- Non-Goals: persisting any other key (nothing else mutates at runtime); persisting `--model/-m` flags (per-run overrides); secrets in `config.lua`; fixing the app→ui prepared-config plumbing (known T117 drift, separate change).

## Decisions

1. **Bootstrap serializes `default_config()` with section comments.** One writer in `config.lua`, invoked from `M.load` when the file is missing (mkdir `~/.tether` first). Rationale: single source for defaults already exists; generated file parses back to identical effective config. Alternative (static template file) rejected: two sources of defaults drift.
2. **Targeted text update of the two top-level keys, not load→modify→serialize.** A full rewrite would drop comments and break files with conditional logic after/around the table. The updater patches `^provider = ...` / `^model = ...` lines in place; keys absent → appended before the table close only when the structure is recognizable, otherwise fail closed (in-memory pick kept, debug-logged, session unaffected). Only top-level keys are managed; `providers.<id>.model` stays hand-edited and keeps precedence per the existing resolution chain.
3. **Migration inside `M.load`, once.** If `model.lua` exists and `config.lua` has no explicit `provider`/`model`, apply it, write through to `config.lua`, then remove `model.lua`. Afterwards `save_model`/`load_model` and the T177 side-file assertions are deleted (T177 is reworked to the new behavior, not dropped).
4. **Precedence becomes trivially last-write-wins** inside the single file; the in-memory chain (`--model/-m` > file) is unchanged.

## Risks / Trade-offs

- [Risk] Two tether processes pick models concurrently → last write wins; acceptable for a single-user TUI, no locking.
- [Risk] Exotic hand-written configs (computed `return`, keys built by code) defeat the text patch → Mitigation: fail closed, never corrupt; bootstrap covers the common case with a known template.
- [Risk] ui.lua main-chunk 200-locals limit (hit during T176) → Mitigation: new helpers as `M.*` fields, zero new chunk locals.
- [Risk] Tests touching real `~/.tether` → Mitigation: explicit `home` parameter everywhere, temp dirs, real HOME never written (existing T87b/T177 pattern).

## Migration Plan

1. Ship bootstrap + write-through + `model.lua` migration in one release (no flag).
2. Rollback: user deletes the two keys (or the file) — loader falls back to defaults as today. No data loss path: side-file removal happens only after a verified write.

## Open Questions

None. Comment wording of the generated template is deferrable to implementation.
