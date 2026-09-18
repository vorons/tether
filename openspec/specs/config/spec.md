
# config

## Purpose

Configuration: `~/.tether/config.lua` loading with defaults, deep
merge, API key env resolution, system prompt resolution, and
machine-managed auto-approve persistence.


## Requirements

### Requirement: Defaults

A fresh install (no `~/.tether/config.lua`) SHALL run with defaults: provider openai, api_key_env OPENAI_API_KEY, base_url https://api.openai.com/v1, model gpt-4o-mini, providers table `{ openai = { api_key_env = "OPENAI_API_KEY", base_url = "https://api.openai.com/v1" }, anthropic = { api_key_env = "ANTHROPIC_API_KEY", base_url = "https://api.anthropic.com" }, gemini = { api_key_env = "GEMINI_API_KEY", base_url = "https://generativelanguage.googleapis.com" } }`, workspace nil (cwd at runtime), allow_outside_workspace false, auto_approve {}, context {max_tokens 32768, summarize_at 0.7}, retries 3, ui {theme default, header false, keyboard_protocol auto, mouse auto, thinking collapsed, ascii auto, wrap true, collapse {read 20, list 30, grep 15}, input_max_lines 8, alt_screen true, highlight auto, turn_separators true, path_completion true}, tools {run_shell {timeout 120}}, system_prompt nil, skills_dirs nil, agents_files {}, log_level info.

#### Scenario: Missing config file

- **WHEN** the config path does not exist
- **THEN** loading succeeds silently with defaults, including `skills_dirs = nil` and `agents_files = {}`

#### Scenario: TUI defaults present

- **WHEN** the config file is missing and the effective config is inspected
- **THEN** `ui.highlight` is `"auto"`, `ui.turn_separators` is `true`, and `ui.path_completion` is `true`

#### Scenario: Partial ui override keeps the new keys

- **WHEN** the user sets only `ui.turn_separators = false`
- **THEN** that key is overridden and `ui.highlight` and `ui.path_completion` keep their defaults


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
The API key SHALL be resolved for the active provider: `cfg.providers[cfg.provider].api_key_env` when set, otherwise the legacy top-level `cfg.api_key_env` (default OPENAI_API_KEY); missing key SHALL yield the empty string, not an error. The resolved variable name is the only env var read.

#### Scenario: Custom env var name
- **WHEN** `api_key_env = "ANTHROPIC_API_KEY"`
- **THEN** the key is read from that variable

#### Scenario: Per-provider env resolution
- **WHEN** `provider = "gemini"` and `providers.gemini.api_key_env = "GEMINI_API_KEY"`
- **THEN** the key is read from `GEMINI_API_KEY` even when top-level `api_key_env` is `OPENAI_API_KEY`

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
merged into `cfg.auto_approve` on next load.

#### Scenario: Second always is a no-op
- **WHEN** the same key is chosen always twice
- **THEN** the file contains the pattern once

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
