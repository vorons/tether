# Spec Delta

## Purpose

Configuration: `~/.tether/config.lua` loading with defaults, deep
merge, API key env resolution, system prompt resolution, and
machine-managed auto-approve persistence.

## ADDED Requirements

### Requirement: Defaults
A fresh install (no `~/.tether/config.lua`) SHALL run with defaults:
provider openai, api_key_env OPENAI_API_KEY, base_url
https://api.openai.com/v1, model gpt-4o-mini, workspace nil (cwd at
runtime), allow_outside_workspace false, auto_approve {},
context {max_tokens 32768, summarize_at 0.7}, retries 3, ui
{theme default, header false, keyboard_protocol auto, mouse auto,
thinking collapsed, ascii auto, wrap true, collapse {read 20, list
30, grep 15}, input_max_lines 8, alt_screen true}, tools
{run_shell {timeout 120}}, system_prompt nil, log_level info.

#### Scenario: Missing config file
- **WHEN** the config path does not exist
- **THEN** loading succeeds silently with defaults (a missing file is
  not an error)

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
The API key SHALL be read from the environment variable named by
`cfg.api_key_env` (default OPENAI_API_KEY); missing key SHALL yield
the empty string, not an error.

#### Scenario: Custom env var name
- **WHEN** `api_key_env = "ANTHROPIC_API_KEY"`
- **THEN** the key is read from that variable

### Requirement: System prompt resolution
`get_system_prompt` SHALL return, in order: a multi-line
`system_prompt` string (inline text); a string starting with `/` is
treated as a file path to read; any other non-empty string is used
as-is; otherwise nil (built-in prompt).

#### Scenario: File path prompt
- **WHEN** `system_prompt = "/home/me/prompt.md"`
- **THEN** the file content is returned; a missing file yields nil

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
