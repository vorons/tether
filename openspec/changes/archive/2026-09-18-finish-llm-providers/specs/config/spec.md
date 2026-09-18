# Spec Delta: config

## MODIFIED Requirements

### Requirement: Defaults
A fresh install (no `~/.tether/config.lua`) SHALL run with defaults: provider openai, api_key_env OPENAI_API_KEY, base_url https://api.openai.com/v1, model gpt-4o-mini, providers table `{ openai = { api_key_env = "OPENAI_API_KEY", base_url = "https://api.openai.com/v1" }, anthropic = { api_key_env = "ANTHROPIC_API_KEY", base_url = "https://api.anthropic.com" }, gemini = { api_key_env = "GEMINI_API_KEY", base_url = "https://generativelanguage.googleapis.com" } }`, workspace nil (cwd at runtime), allow_outside_workspace false, auto_approve {}, context {max_tokens 32768, summarize_at 0.7}, retries 3, ui {theme default, header false, keyboard_protocol auto, mouse auto, thinking collapsed, ascii auto, wrap true, collapse {read 20, list 30, grep 15}, input_max_lines 8, alt_screen true}, tools {run_shell {timeout 120}}, system_prompt nil, log_level info.

#### Scenario: Missing config file
- **WHEN** the config path does not exist
- **THEN** loading succeeds silently with defaults (a missing file is not an error)

### Requirement: API key from env
The API key SHALL be resolved for the active provider: `cfg.providers[cfg.provider].api_key_env` when set, otherwise the legacy top-level `cfg.api_key_env` (default OPENAI_API_KEY); missing key SHALL yield the empty string, not an error. The resolved variable name is the only env var read.

#### Scenario: Custom env var name
- **WHEN** `api_key_env = "ANTHROPIC_API_KEY"`
- **THEN** the key is read from that variable

#### Scenario: Per-provider env resolution
- **WHEN** `provider = "gemini"` and `providers.gemini.api_key_env = "GEMINI_API_KEY"`
- **THEN** the key is read from `GEMINI_API_KEY` even when top-level `api_key_env` is `OPENAI_API_KEY`

## ADDED Requirements

### Requirement: Provider selection
`cfg.provider` SHALL be one of `openai`, `anthropic`, `gemini` (default `openai`). `base_url` and `model` resolve per provider: `cfg.providers[cfg.provider].base_url` / `.model` when set, otherwise the legacy top-level `cfg.base_url` / `cfg.model`. The `--model/-m` flag and `/model` picker operate on the active provider. An unknown `cfg.provider` value SHALL warn on stderr and behave as `openai`.

#### Scenario: Per-provider model override
- **WHEN** config sets `providers.anthropic.model = "claude-sonnet-4-20250514"` and top-level `model = "gpt-4o-mini"`
- **THEN** with `provider = "anthropic"` the effective model is the Claude model

#### Scenario: Unknown provider warns and falls back
- **WHEN** `provider = "azure"`
- **THEN** a stderr warning names the value and requests behave as `openai`
