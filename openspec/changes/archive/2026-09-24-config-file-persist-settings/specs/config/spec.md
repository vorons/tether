# Spec Delta: config

## MODIFIED Requirements

### Requirement: Defaults

A fresh install (no `~/.tether/config.lua`) SHALL run with defaults: provider openai, api_key_env OPENAI_API_KEY, base_url https://api.openai.com/v1, model gpt-4o-mini, providers table with per-provider `api_key_env` / `base_url` / `model` for every catalog id, plus workspace nil (cwd at runtime), allow_outside_workspace false, auto_approve {}, context {max_tokens 32768, summarize_at 0.7, reserve_tokens 16384, keep_recent_messages 4}, retry {base_delay_ms 2000, max_delay_ms 60000, multiplier 2, max_failures_at_max_delay 3}, ui {theme default, header false, keyboard_protocol auto, mouse auto, thinking collapsed, ascii auto, wrap true, collapse {read 20, list 30, grep 15}, input_max_lines 8, editor_padding_x 0, alt_screen true, highlight auto, turn_separators true, path_completion true}, tools {run_shell {timeout 120}}, system_prompt nil, skills_dirs nil, agents_files {}, log_level info.

The defaults SHALL NOT include a `retries` value or a `retry.max_attempts`: the default retry budget is the policy cutoff (eight attempts at most), not a fixed attempt count.

`context.reserve_tokens` (default 16384) SHALL reserve headroom for the model's reply when deciding to compact; `context.keep_recent_messages` (default 4) SHALL size the unsummarized tail window. A missing or non-numeric value for either key SHALL fall back to its default without failing the session.

#### Scenario: Missing config file

- **WHEN** the config path does not exist
- **THEN** loading succeeds silently with defaults, including `skills_dirs = nil`, `agents_files = {}`, `context.reserve_tokens = 16384`, and `context.keep_recent_messages = 4`

#### Scenario: Missing config file is bootstrapped

- **WHEN** the config path does not exist at startup
- **THEN** loading succeeds with defaults AND the file is created holding those defaults with explanatory comments, including `skills_dirs = nil`, `agents_files = {}`, `context.reserve_tokens = 16384`, and `context.keep_recent_messages = 4`

#### Scenario: TUI defaults present

- **WHEN** the config file is missing and the effective config is inspected
- **THEN** `ui.highlight` is `"auto"`, `ui.turn_separators` is `true`, and `ui.path_completion` is `true`

#### Scenario: Partial ui override keeps the new keys

- **WHEN** the user sets only `ui.turn_separators = false`
- **THEN** that key is overridden and `ui.highlight` and `ui.path_completion` keep their defaults

#### Scenario: Editor padding default

- **WHEN** the config file is missing and the effective config is inspected
- **THEN** `ui.editor_padding_x` is 0

#### Scenario: Retry defaults present

- **WHEN** the config file is missing and the effective config is inspected
- **THEN** `retry.base_delay_ms` is 2000, `retry.max_delay_ms` is 60000, `retry.multiplier` is 2, `retry.max_failures_at_max_delay` is 3, and neither `retries` nor `retry.max_attempts` is set

#### Scenario: Malformed reserve_tokens falls back

- **WHEN** the user sets `context.reserve_tokens = "lots"`
- **THEN** loading succeeds and the effective reserve is 16384

#### Scenario: Preset default resolves

- **WHEN** the config file is missing and `provider = "xai"`
- **THEN** the effective `base_url` is `https://api.x.ai/v1` and `api_key_env` is `XAI_API_KEY`

## ADDED Requirements

### Requirement: Config file bootstrap

When `~/.tether/config.lua` does not exist, the first load SHALL create it (including the `~/.tether` directory when needed) containing the default values with a comment per section, so all settings are discoverable and hand-editable. Per-provider endpoints stay catalog-driven: the generated file carries an empty `providers` table with an example override, so catalog updates keep flowing. A file that already exists SHALL never be overwritten or reformatted by the bootstrap. When the file or its directory cannot be created, loading SHALL still succeed with in-memory defaults and SHALL NOT fail the session.

#### Scenario: First run creates a commented file

- **WHEN** `~/.tether/config.lua` is absent and the config loads
- **THEN** the file exists afterwards, parses as a Lua table, and a fresh load from it yields the same effective config as the defaults

#### Scenario: Existing file untouched

- **WHEN** `~/.tether/config.lua` exists with user edits and the config loads
- **THEN** the file byte content is unchanged and the edits take effect

#### Scenario: Unwritable location degrades

- **WHEN** the config directory cannot be created
- **THEN** loading succeeds with in-memory defaults and the session starts

### Requirement: Model persistence in config file

The `/model` picker SHALL persist the picked `provider` and `model` into `~/.tether/config.lua`, so a restart restores them. The write SHALL update only those two keys and preserve everything else in the file byte-for-byte (comments, unknown keys, user logic). Only `provider` and `model` are ever machine-written; secrets SHALL never be written to `config.lua`. A failed write SHALL NOT fail the pick: the in-memory selection still applies for the session.

The retired `~/.tether/model.lua` side file SHALL be migrated once: when it exists and `config.lua` carries no non-default `provider`/`model` (a bootstrapped file holds defaults, which count as non-explicit), its value moves into `config.lua` on load and the side file is removed.

#### Scenario: Pick survives restart

- **WHEN** the user picks `gpt-4o` via `/model` and restarts
- **THEN** the effective `model` is `gpt-4o` with no user edit in between

#### Scenario: File preserves user content

- **WHEN** `config.lua` holds comments and custom keys and the user picks a model
- **THEN** after the pick the comments and custom keys are intact and only the `provider`/`model` lines changed

#### Scenario: Hand edit wins

- **WHEN** `config.lua` explicitly sets `model` and the user picks another model, then restarts
- **THEN** the effective `model` is the picked one (the pick rewrote the key); a later hand edit to the key takes effect on the next load

#### Scenario: Side file migrates once

- **WHEN** `~/.tether/model.lua` holds a pick and `config.lua` has no explicit `provider`/`model`
- **THEN** the first load applies the pick, writes it into `config.lua`, and removes `model.lua`
