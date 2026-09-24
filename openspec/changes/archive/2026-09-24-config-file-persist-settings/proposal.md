# Proposal

## Why

A `/model` pick only lives in memory, so after a restart the default model returns (reported bug). Separately, `~/.tether/config.lua` is optional and invisible: a fresh install has no file, users cannot discover available settings, and machine state (`~/.tether/model.lua`) drifts apart from the one config file users expect to own. Making `config.lua` the single source of truth fixes the persistence bug and the discoverability gap together.

## What Changes

- On startup, when `~/.tether/config.lua` is missing, tether creates it filled with default values and comments (bootstrap). Loading semantics otherwise unchanged (deep merge over defaults).
- The `/model` picker persists the picked `provider` + `model` into `~/.tether/config.lua` via a targeted key update that preserves the rest of the file (comments, unknown keys, user logic outside the two keys).
- The `~/.tether/model.lua` side file (introduced as a stopgap) is retired: its value migrates into `config.lua` once on first load, then the file is removed.
- Only `provider` and `model` are machine-written. They are the only settings mutable at runtime today (`pick.model`); everything else remains hand-edited. Secrets never touch `config.lua` (`api_key` stays in `auth.json`).
- All settings continue to be read from `config.lua` via `config.load` (already the case).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `config`: bootstrap-on-missing requirement (replaces the silent-defaults behavior for a missing file); new model-persistence requirement (write-through of `provider`/`model`, migration of `model.lua`).
- `tui`: `/model` Enter additionally persists the pick to `config.lua` (extends the existing "Model Enter changes the model" scenario).

## Impact

- `src/tether/config.lua`: bootstrap writer, key-targeted file update, one-time `model.lua` migration, precedence unchanged (explicit config wins — now trivially, since the pick lives in the config).
- `src/tether/ui.lua`: `pick.model` writes through to `config.lua` instead of the side file (best-effort, in-memory state still applies first).
- `tests/lua_tests.lua`: regression tests for bootstrap, write-through, comment preservation, migration.
- Specs: `config` + `tui` deltas. No provider/auth/session behavior changes.
