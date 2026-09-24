# Spec Delta: config

## MODIFIED Requirements

### Requirement: Defaults

A fresh install (no `~/.tether/config.lua`) SHALL run with defaults: provider openai, api_key_env OPENAI_API_KEY, base_url https://api.openai.com/v1, model gpt-4o-mini, providers table with per-provider `api_key_env` / `base_url` / `model` for every catalog id — the original three (`openai`, `anthropic`, `gemini`) plus all Tier-A presets (deepseek `DEEPSEEK_API_KEY` / `https://api.deepseek.com`, groq `GROQ_API_KEY` / `https://api.groq.com/openai/v1`, cerebras `CEREBRAS_API_KEY` / `https://api.cerebras.ai/v1`, xai `XAI_API_KEY` / `https://api.x.ai/v1`, openrouter `OPENROUTER_API_KEY` / `https://openrouter.ai/api/v1`, fireworks `FIREWORKS_API_KEY` / `https://api.fireworks.ai/inference`, together `TOGETHER_API_KEY` / `https://api.together.ai/v1`, baseten `BASETEN_API_KEY` / `https://inference.baseten.co/v1`, nvidia `NVIDIA_API_KEY` / `https://integrate.api.nvidia.com/v1`, moonshotai(+cn) `MOONSHOT_API_KEY`, huggingface `HF_TOKEN` / `https://router.huggingface.co/v1`, zai(+coding-cn) `ZAI_API_KEY` / `ZAI_CODING_CN_API_KEY`, qwen-token-plan(+cn/+individual), xiaomi(+token-plan-cn/ams/sgp), ant-ling `ANT_LING_API_KEY`, mistral `MISTRAL_API_KEY` / `https://api.mistral.ai/v1`, meta `META_API_KEY` / `https://api.meta.ai/v1`, kimi-coding `KIMI_API_KEY`, minimax(+cn) `MINIMAX_API_KEY` / `MINIMAX_CN_API_KEY`, vercel-ai-gateway `AI_GATEWAY_API_KEY`, github-copilot `COPILOT_GITHUB_TOKEN`, azure-openai `AZURE_OPENAI_API_KEY`, cloudflare-workers-ai / cloudflare-ai-gateway `CLOUDFLARE_API_KEY`, opencode(+go) `OPENCODE_API_KEY`, radius `RADIUS_API_KEY`, llama `LLAMA_API_KEY` / `http://127.0.0.1:8080`) and Tier-B entries (amazon-bedrock, google-vertex, openai-codex) — plus workspace nil (cwd at runtime), allow_outside_workspace false, auto_approve {}, context {max_tokens 32768, summarize_at 0.7, reserve_tokens 16384, keep_recent_messages 4}, retry {base_delay_ms 2000, max_delay_ms 60000, multiplier 2, max_failures_at_max_delay 3}, ui {theme default, header false, keyboard_protocol auto, mouse auto, thinking collapsed, ascii auto, wrap true, collapse {read 20, list 30, grep 15}, input_max_lines 8, editor_padding_x 0, alt_screen true, highlight auto, turn_separators true, path_completion true}, tools {run_shell {timeout 120}}, system_prompt nil, skills_dirs nil, agents_files {}, log_level info.

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

#### Scenario: Preset default resolves

- **WHEN** the config file is missing and `provider = "xai"`
- **THEN** the effective `base_url` is `https://api.x.ai/v1` and `api_key_env` is `XAI_API_KEY`

### Requirement: Provider selection
`cfg.provider` SHALL be any catalog id (default `openai`). `base_url`, `model`, and `api_key_env` resolve per provider: `cfg.providers[cfg.provider].base_url` / `.model` / `.api_key_env` when set, otherwise the legacy top-level `cfg.base_url` / `cfg.model` / `cfg.api_key_env`. The `--model/-m` flag and `/model` picker operate on the active provider. An unknown `cfg.provider` value SHALL warn on stderr and behave as `openai`.

#### Scenario: Per-provider model override
- **WHEN** config sets `providers.anthropic.model = "claude-sonnet-4-20250514"` and top-level `model = "gpt-4o-mini"`
- **THEN** with `provider = "anthropic"` the effective model is the Claude model

#### Scenario: Unknown provider warns and falls back
- **WHEN** `provider = "azure"`
- **THEN** a stderr warning names the value and requests behave as `openai`

#### Scenario: Preset env resolution
- **WHEN** `provider = "deepseek"` with no stored credential
- **THEN** the key is read from `DEEPSEEK_API_KEY`
