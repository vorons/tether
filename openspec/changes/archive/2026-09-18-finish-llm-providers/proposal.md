# Proposal: finish-llm-providers

## Why

`tether` today speaks only OpenAI-compatible `POST <base_url>/chat/completions` (SSE). `config.provider` is dead weight (always `"openai"`), and Anthropic/Google adapters are explicitly deferred in `docs/design.md` §2 and `docs/tech-spec.md`. Users with only an Anthropic or Gemini key cannot use tether at all.

## What Changes

- Provider dispatcher in Lua: `cfg.provider` (`openai` | `anthropic` | `gemini`) selects an adapter at `api.stream()` / `api.list_models*()` time. Default stays `openai`; unknown value falls back to `openai` with a stderr warning (no crash, no behavior change for existing installs).
- Anthropic adapter (`src/tether/providers/anthropic.lua`): `POST <base_url>/v1/messages` with `x-api-key` + `anthropic-version: 2023-06-01`, SSE mapping `content_block_delta.text_delta → text_delta`, `input_json_delta → tool_call_delta`, `message_delta/message_stop → done/usage`. Tool definitions converted OpenAI-style → Anthropic `tools` + `tool_choice`. History converted: `tool` role → `tool_result` blocks.
- Gemini adapter (`src/tether/providers/gemini.lua`): `POST <base_url>/v1beta/models/<model>:streamGenerateContent?key=...` (SSE) with REST `generateContent` fallback, mapping `candidates[].content.parts[].text → text_delta`, `functionCall → tool_call_start/delta`, `usageMetadata → usage`. API key via query param (Google convention), never in argv — passed via body-file/curl config pattern already used for headers.
- Shared transport stays in one place: auth-header temp file (mode 600), body temp file with `--data-binary @file`, curl pipe via `tether.open_pipe`, retry/backoff + `Retry-After`, non-SSE error surfacing. Adapters differ only in URL/headers/request JSON/SSE parsing.
- Config: per-provider `api_key_env` / `base_url` / `model` resolution (`cfg.providers.<name>` table overrides, legacy top-level `api_key_env`/`base_url`/`model` keep working as `openai` defaults). `--model` flag and `/model` picker use the active provider's live list with static fallback.
- Agent loop untouched: adapters emit the existing canonical events (`text_delta`, `tool_call_start/delta`, `usage`, `retry`, `error`, `done`), so `agent.lua` tool assembly, confirmation and resume logic do not change.

## Capabilities

### New Capabilities
- None as standalone specs — provider behavior is expressed as deltas on the two capabilities that own it.

### Modified Capabilities
- `api-client`: multi-provider dispatch + Anthropic/Gemini request mapping and SSE parsing, preserving canonical events, key handling, retry and model-listing contracts.
- `config`: provider selection and per-provider key/URL/model resolution with backward-compatible defaults.

## Impact

- Code: `src/tether/api.lua` (becomes dispatcher + shared transport), new `src/tether/providers/{openai,anthropic,gemini}.lua`, `src/tether/config.lua` (provider table), `tools/embed.lua` module list, `tests/lua_tests.lua` (new cases).
- Docs: `README.md` (provider setup), `docs/tech-spec.md` (deferred item resolved).
- No C host changes; no agent/tool/session/UI contract changes. Existing OpenAI configs behave identically.
