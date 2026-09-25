# Spec Delta

## MODIFIED Requirements

### Requirement: Defaults

A fresh install (no `~/.tether/config.lua`) SHALL run with defaults: provider openai, api_key_env OPENAI_API_KEY, base_url https://api.openai.com/v1, model gpt-4o-mini, reasoning off, providers table with per-provider `api_key_env` / `base_url` / `model` for every catalog id (the defaults cover the full Tier-A list including `agnes`, `agnes-cn`, `llama` at `http://127.0.0.1:8080/v1`, and the moonshot/qwen/xiaomi regional variants — the catalog file is the source of truth for per-id values), plus workspace nil (cwd at runtime), allow_outside_workspace false, auto_approve {}, context {max_tokens 32768, summarize_at 0.7, reserve_tokens 16384, keep_recent_messages 4}, retry {base_delay_ms 2000, max_delay_ms 60000, multiplier 2, max_failures_at_max_delay 3}, ui {theme default, header false, keyboard_protocol auto, mouse auto, thinking collapsed, ascii auto, wrap true, collapse {read 20, list 30, grep 15}, input_max_lines 8, editor_padding_x 0, alt_screen true, highlight auto, turn_separators true, path_completion true}, tools {run_shell {timeout 120}}, system_prompt nil, skills_dirs nil, agents_files {}, log_level info.

The defaults SHALL NOT include a `retries` value or a `retry.max_attempts`: the default retry budget is the policy cutoff (eight attempts at most), not a fixed attempt count.

`context.reserve_tokens` (default 16384) SHALL reserve headroom for the model's reply when deciding to compact; `context.keep_recent_messages` (default 4) SHALL size the unsummarized tail window. A missing or non-numeric value for either key SHALL fall back to its default without failing the session.

`reasoning` SHALL accept only `off`, `low`, `medium` and `high`; a missing value SHALL default to `off`, and any other value SHALL fall back to `off` without failing the session.

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

#### Scenario: Reasoning default present

- **WHEN** the config file is missing and the effective config is inspected
- **THEN** `reasoning` is `"off"`

#### Scenario: Unknown reasoning level falls back

- **WHEN** the user sets `reasoning = "turbo"`
- **THEN** loading succeeds and the effective `reasoning` is `"off"`

### Requirement: Model persistence in config file

The `/model` picker SHALL persist the picked `provider` and `model` into `~/.tether/config.lua`, and the `/think` picker SHALL persist the picked `reasoning` level there, so a restart restores them. The write SHALL update only those keys and preserve everything else in the file byte-for-byte (comments, unknown keys, user logic). Only `provider`, `model` and `reasoning` are ever machine-written; secrets SHALL never be written to `config.lua`. A failed write SHALL NOT fail the pick: the in-memory selection still applies for the session. Persistence and migration apply to recognizable files only — a file the rewriter cannot safely re-emit (e.g. a hand-minified one-liner or exotic Lua) fails closed: the write is skipped, the in-memory pick still applies, and no data is lost.

The retired `~/.tether/model.lua` side file SHALL be migrated once: when it exists and `config.lua` carries no explicit `provider`/`model` — a key that is absent or holds the bootstrap default counts as non-explicit, so a hand-written pick in the config (even one matching the default) always wins over the side file — its value moves into `config.lua` on load and the side file is removed.

#### Scenario: Pick survives restart

- **WHEN** the user picks `gpt-4o` via `/model` and restarts
- **THEN** the effective `model` is `gpt-4o` with no user edit in between

#### Scenario: Reasoning pick survives restart

- **WHEN** the user picks `medium` via `/think` and restarts
- **THEN** the effective `reasoning` is `medium` with no user edit in between

#### Scenario: File preserves user content

- **WHEN** `config.lua` holds comments and custom keys and the user picks a model
- **THEN** after the pick the comments and custom keys are intact and only the `provider`/`model` lines changed

#### Scenario: Hand edit wins

- **WHEN** `config.lua` explicitly sets `model` and the user picks another model, then restarts
- **THEN** the effective `model` is the picked one (the pick rewrote the key); a later hand edit to the key takes effect on the next load

#### Scenario: Side file migrates once

- **WHEN** `~/.tether/model.lua` holds a pick and `config.lua` has no explicit `provider`/`model`
- **THEN** the first load applies the pick, writes it into `config.lua`, and removes `model.lua`

#### Scenario: Hand-written default is explicit

- **WHEN** `config.lua` hand-writes `model = "gpt-4o-mini"` (equal to the bootstrap default) and `model.lua` holds another pick
- **THEN** the migration does not run: the explicit config value wins and `model.lua` stays on disk

#### Scenario: Unrecognizable config fails closed

- **WHEN** `config.lua` is a one-liner the rewriter cannot re-emit and the user picks a model
- **THEN** the pick applies for the session, the file is left untouched, and no error is raised
