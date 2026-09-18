# Spec Delta

## MODIFIED Requirements

### Requirement: Defaults

A fresh install (no `~/.tether/config.lua`) SHALL run with defaults: provider openai, api_key_env OPENAI_API_KEY, base_url https://api.openai.com/v1, model gpt-4o-mini, providers table `{ openai = { api_key_env = "OPENAI_API_KEY", base_url = "https://api.openai.com/v1" }, anthropic = { api_key_env = "ANTHROPIC_API_KEY", base_url = "https://api.anthropic.com" }, gemini = { api_key_env = "GEMINI_API_KEY", base_url = "https://generativelanguage.googleapis.com" } }`, workspace nil (cwd at runtime), allow_outside_workspace false, auto_approve {}, context {max_tokens 32768, summarize_at 0.7}, retries 3, ui {theme default, header false, keyboard_protocol auto, mouse auto, thinking collapsed, ascii auto, wrap true, collapse {read 20, list 30, grep 15}, input_max_lines 8, alt_screen true}, tools {run_shell {timeout 120}}, system_prompt nil, skills_dirs nil, agents_files {}, log_level info.

#### Scenario: Missing config file

- **WHEN** the config path does not exist
- **THEN** loading succeeds silently with defaults, including `skills_dirs = nil` and `agents_files = {}`

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
