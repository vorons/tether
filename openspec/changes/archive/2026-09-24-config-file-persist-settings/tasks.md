# Tasks

## 1. Bootstrap

- [x] 1.1 Add commented-defaults writer to `config.lua` and call it from `M.load` when the file is missing; verify a fresh temp home gains a parseable `config.lua` whose reload yields identical effective config
- [x] 1.2 Cover failure paths: existing file byte-identical after load; unwritable directory still loads in-memory defaults; verify via unit tests with temp homes

## 2. Write-through

- [x] 2.1 Add targeted `provider`/`model` updater to `config.lua` (in-place line patch, append only into recognizable structure, fail closed otherwise); verify comments/unknown keys survive byte-for-byte and exotic files are left untouched
- [x] 2.2 Point `pick.model` (ui.lua) at the `config.lua` updater instead of the side file, best-effort via pcall; verify `/model` Enter updates the file and the session state as before
- [x] 2.3 Secrets audit: verify no path writes `api_key`/tokens to `config.lua` (pick, login, `-m` flows)

## 3. Migration

- [x] 3.1 One-time `model.lua`→`config.lua` migration in `M.load` (apply only with no explicit `provider`/`model`, remove side file after verified write); verify with a staged side file in a temp home
- [x] 3.2 Delete `save_model`/`load_model`/`_model_path` and rework T177 to the new behavior (bootstrap, write-through, preservation, migration); verify `lua tests/lua_tests.lua` green

## 4. Integration

- [x] 4.1 Run full `make test` green (luac, lua/context suites, e2e, host smoke/primitives)
- [x] 4.2 Manual check with real HOME backup: fresh start creates commented `config.lua`; `/model` pick survives restart; hand edit still wins on next load
