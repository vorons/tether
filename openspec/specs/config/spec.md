
# config

## Purpose

Configuration: `~/.tether/config.lua` loading with defaults, deep
merge, API key env resolution, system prompt resolution, and
machine-managed auto-approve persistence.

## Requirements

### Requirement: Defaults

A fresh install (no `~/.tether/config.lua`) SHALL run with defaults: provider openai, api_key_env OPENAI_API_KEY, base_url https://api.openai.com/v1, model gpt-4o-mini, providers table `{ openai = { api_key_env = "OPENAI_API_KEY", base_url = "https://api.openai.com/v1" }, anthropic = { api_key_env = "ANTHROPIC_API_KEY", base_url = "https://api.anthropic.com" }, gemini = { api_key_env = "GEMINI_API_KEY", base_url = "https://generativelanguage.googleapis.com" } }`, workspace nil (cwd at runtime), allow_outside_workspace false, auto_approve {}, context {max_tokens 32768, summarize_at 0.7, reserve_tokens 16384, keep_recent_messages 4}, retry {base_delay_ms 2000, max_delay_ms 60000, multiplier 2, max_failures_at_max_delay 3}, ui {theme default, header false, keyboard_protocol auto, mouse auto, thinking collapsed, ascii auto, wrap true, collapse {read 20, list 30, grep 15}, input_max_lines 8, editor_padding_x 0, alt_screen true, highlight auto, turn_separators true, path_completion true}, tools {run_shell {timeout 120}}, system_prompt nil, skills_dirs nil, agents_files {}, log_level info.

The defaults SHALL NOT include a `retries` value or a `retry.max_attempts`: the default retry budget is the policy cutoff (eight attempts at most), not a fixed attempt count.

`context.reserve_tokens` (default 16384) SHALL reserve headroom for the model's reply when deciding to compact; `context.keep_recent_messages` (default 4) SHALL size the unsummarized tail window. A missing or non-numeric value for either key SHALL fall back to its default without failing the session.

#### Scenario: Missing config file

- **WHEN** the config path does not exist
- **THEN** loading succeeds silently with defaults, including `skills_dirs = nil`, `agents_files = {}`, `context.reserve_tokens = 16384`, and `context.keep_recent_messages = 4`

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

### Requirement: Deep merge load
User config SHALL be deep-merged over defaults: tables merge
recursively, scalars override. A config file that fails to load or
return a table SHALL print `tether: config error: ...` to stderr and
fall back to defaults without crashing.

#### Scenario: Partial ui override
- **WHEN** the user sets only `ui.theme = "mono"`
- **THEN** all other ui keys keep their defaults

#### Scenario: Broken file
- **WHEN** config.lua has a syntax error
- **THEN** a stderr warning is printed and defaults are used

### Requirement: API key from env
The credential for the active provider SHALL be resolved in this order: stored OAuth access token from `~/.tether/auth.json` when present and unexpired (refreshing once when expired and a refresh token exists), then stored `kind = "api_key"` entry, then `cfg.providers[cfg.provider].api_key_env` when set, otherwise the legacy top-level `cfg.api_key_env` (default OPENAI_API_KEY); missing key SHALL yield the empty string, not an error. The resolved variable name is the only env var read when the env path is taken. The store SHALL NOT be required: absence behaves exactly as today's env-only resolution.

#### Scenario: Custom env var name
- **WHEN** `api_key_env = "ANTHROPIC_API_KEY"`
- **THEN** the key is read from that variable when no stored credential applies

#### Scenario: Per-provider env resolution
- **WHEN** `provider = "gemini"` and `providers.gemini.api_key_env = "GEMINI_API_KEY"`
- **THEN** the key is read from `GEMINI_API_KEY` even when top-level `api_key_env` is `OPENAI_API_KEY`

#### Scenario: Stored token wins over env
- **WHEN** `auth.json` holds an unexpired oauth token for anthropic and env also has a key
- **THEN** requests use the stored token

#### Scenario: Store unreadable
- **WHEN** `auth.json` exists but is corrupt JSON
- **THEN** resolution falls back to env (or empty) without failing the session

### Requirement: System prompt resolution
`get_system_prompt` SHALL resolve the base prompt: a multi-line `system_prompt` string (inline text); a string starting with `/` is treated as a file path to read; any other non-empty string is used as-is; otherwise nil (built-in prompt). The composed prompt returned to the agent SHALL be that base followed by the AGENTS.md and skills sections produced by context-injection rules, via `context.compose`; when no AGENTS.md file and no skills are discovered, the result SHALL be identical to the base.

#### Scenario: File path prompt
- **WHEN** `system_prompt = "/home/me/prompt.md"`
- **THEN** the file content is returned; a missing file yields nil

#### Scenario: Composed with AGENTS.md and skills
- **WHEN** `system_prompt` is nil and one AGENTS.md and two skills are discovered
- **THEN** the returned prompt is the built-in base, then the AGENTS.md section, then the two-skill index

#### Scenario: base only
- **WHEN** `config.system_prompt` is nil and no AGENTS.md or skills exist
- **THEN** the composed prompt equals the built-in default tool description

### Requirement: Auto-approve persistence file
`[A] always` confirmations SHALL be persisted to
`~/.tether/auto_approve.lua` as a Lua table of anchored
`^tool:path$` patterns with a dated comment header. The file SHALL
be deduplicated (same pattern not appended twice) and SHALL be
merged into `cfg.auto_approve` on next load. Loading SHALL tolerate a
missing or unreadable file by contributing no patterns and SHALL NOT
fail the session.

#### Scenario: Second always is a no-op
- **WHEN** the same key is chosen always twice
- **THEN** the file contains the pattern once

#### Scenario: Persisted patterns load on next start
- **WHEN** `~/.tether/auto_approve.lua` holds `^run:/tmp/x$` and a new process loads the config
- **THEN** `cfg.auto_approve` contains that pattern and a later `run` with cwd `/tmp/x` skips confirmation

#### Scenario: Missing persistence file
- **WHEN** `~/.tether/auto_approve.lua` does not exist
- **THEN** loading succeeds with `cfg.auto_approve = {}`

### Requirement: Workspace defaults to cwd
When neither `-w` nor `config.workspace` is set, the workspace SHALL
be the process cwd, resolved through realpath with symlinks
expanded. `-w` overrides the config value.

#### Scenario: -w wins over config
- **WHEN** config sets workspace `/a` and the user passes `-w /b`
- **THEN** the effective workspace is the realpath of /b

### Requirement: Provider selection
`cfg.provider` SHALL be one of `openai`, `anthropic`, `gemini` (default `openai`). `base_url` and `model` resolve per provider: `cfg.providers[cfg.provider].base_url` / `.model` when set, otherwise the legacy top-level `cfg.base_url` / `cfg.model`. The `--model/-m` flag and `/model` picker operate on the active provider. An unknown `cfg.provider` value SHALL warn on stderr and behave as `openai`.

#### Scenario: Per-provider model override
- **WHEN** config sets `providers.anthropic.model = "claude-sonnet-4-20250514"` and top-level `model = "gpt-4o-mini"`
- **THEN** with `provider = "anthropic"` the effective model is the Claude model

#### Scenario: Unknown provider warns and falls back
- **WHEN** `provider = "azure"`
- **THEN** a stderr warning names the value and requests behave as `openai`
