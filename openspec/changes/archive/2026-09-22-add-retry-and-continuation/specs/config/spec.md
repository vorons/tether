# Spec Delta

## ADDED Requirements

### Requirement: Retry configuration resolution
The retry policy SHALL be configured by a `retry` table in
`~/.tether/config.lua`, merged over the defaults so a partial table
keeps the other defaults:

- `retry.base_delay_ms` (default 2000)
- `retry.max_delay_ms` (default 60000)
- `retry.multiplier` (default 2)
- `retry.max_failures_at_max_delay` (default 3)
- `retry.max_attempts` (default unset) — an optional hard cap on the
  number of attempts in one turn.

A value that is missing or is not a usable number SHALL fall back to its
default without failing the session, so a malformed retry setting can
never leave the agent without a schedule.

A legacy top-level `retries` number SHALL be honored as
`retry.max_attempts` when `retry.max_attempts` is not set, so an
existing configuration keeps its attempt cap; when both are set,
`retry.max_attempts` wins. With neither set, attempts are bounded only
by the policy's cutoff.

#### Scenario: Partial retry table
- **WHEN** the user sets only `retry.base_delay_ms = 5000`
- **THEN** the base delay is 5 seconds and the other retry values keep
  their defaults

#### Scenario: Legacy retries caps attempts
- **WHEN** the config sets `retries = 5` and no `retry.max_attempts`
- **THEN** a turn makes at most 5 attempts

#### Scenario: The new key wins
- **WHEN** the config sets both `retries = 5` and
  `retry.max_attempts = 2`
- **THEN** a turn makes at most 2 attempts

#### Scenario: Malformed retry value
- **WHEN** `retry.base_delay_ms` is the string `"soon"`
- **THEN** the session starts and the base delay is the default 2000 ms

#### Scenario: No cap by default
- **WHEN** the config sets neither `retries` nor `retry.max_attempts`
- **THEN** attempts are bounded only by the policy cutoff

## MODIFIED Requirements

### Requirement: Defaults

A fresh install (no `~/.tether/config.lua`) SHALL run with defaults: provider openai, api_key_env OPENAI_API_KEY, base_url https://api.openai.com/v1, model gpt-4o-mini, providers table `{ openai = { api_key_env = "OPENAI_API_KEY", base_url = "https://api.openai.com/v1" }, anthropic = { api_key_env = "ANTHROPIC_API_KEY", base_url = "https://api.anthropic.com" }, gemini = { api_key_env = "GEMINI_API_KEY", base_url = "https://generativelanguage.googleapis.com" } }`, workspace nil (cwd at runtime), allow_outside_workspace false, auto_approve {}, context {max_tokens 32768, summarize_at 0.7}, retry {base_delay_ms 2000, max_delay_ms 60000, multiplier 2, max_failures_at_max_delay 3}, ui {theme default, header false, keyboard_protocol auto, mouse auto, thinking collapsed, ascii auto, wrap true, collapse {read 20, list 30, grep 15}, input_max_lines 8, alt_screen true, highlight auto, turn_separators true, path_completion true}, tools {run_shell {timeout 120}}, system_prompt nil, skills_dirs nil, agents_files {}, log_level info.

The defaults SHALL NOT include a `retries` value or a
`retry.max_attempts`: the default retry budget is the policy cutoff
(eight attempts at most), not a fixed attempt count.

#### Scenario: Missing config file

- **WHEN** the config path does not exist
- **THEN** loading succeeds silently with defaults, including `skills_dirs = nil` and `agents_files = {}`

#### Scenario: TUI defaults present

- **WHEN** the config file is missing and the effective config is inspected
- **THEN** `ui.highlight` is `"auto"`, `ui.turn_separators` is `true`, and `ui.path_completion` is `true`

#### Scenario: Partial ui override keeps the new keys

- **WHEN** the user sets only `ui.turn_separators = false`
- **THEN** that key is overridden and `ui.highlight` and `ui.path_completion` keep their defaults

#### Scenario: Retry defaults present

- **WHEN** the config file is missing and the effective config is inspected
- **THEN** `retry.base_delay_ms` is 2000, `retry.max_delay_ms` is 60000, `retry.multiplier` is 2, `retry.max_failures_at_max_delay` is 3, and neither `retries` nor `retry.max_attempts` is set
