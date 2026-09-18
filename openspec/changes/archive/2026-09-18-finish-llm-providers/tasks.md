# Tasks: finish-llm-providers

## 1. Dispatcher + shared transport

- [x] 1.1 Split `src/tether/api.lua` into dispatcher + `src/tether/providers/openai.lua` with byte-identical OpenAI behavior, and verify `make test` stays green
- [x] 1.2 Add `cfg.provider` dispatch (`openai` default, unknown → `openai` + stderr warning) and verify unknown provider warns and streams via OpenAI path
- [x] 1.3 Register new provider modules in `tools/embed.lua` and verify the single binary includes them (`make && ./tether --version`)

## 2. Anthropic adapter

- [x] 2.1 Implement Anthropic `build_request` (history → messages with `tool_result`/`tool_use`, static tools → `tools` + `tool_choice`, `max_tokens` default) and verify against `specs/api-client` tool round-trip scenario via unit test
- [x] 2.2 Implement Anthropic SSE parsing (`text_delta` → `text_delta`, `input_json_delta` by index → raw `tool_call_delta`, `message_delta/stop` → `usage`/`done`) and verify `tests/lua_tests.lua` covers start/delta-by-index/usage cases
- [x] 2.3 Wire `x-api-key` + `anthropic-version` header-file auth and per-provider `list_models` (`GET /v1/models` + static Claude fallback), and verify no key appears in `ps` output during a request

## 3. Gemini adapter

- [x] 3.1 Implement Gemini `build_request` (history → `contents/parts`, tools → `functionDeclarations`) and verify `functionCall` round-trip emits `tool_call_start` + raw delta per spec scenario
- [x] 3.2 Implement Gemini SSE parsing (`parts[].text` → `text_delta`, `usageMetadata` → `usage`) plus `generateContent` non-SSE fallback normalizing to the same events, and verify both paths via unit tests
- [x] 3.3 Wire `?key=` auth (file-sourced, never logged) and per-provider `list_models` (`GET /v1beta/models` parsing `name` + static Gemini fallback), and verify missing key returns "no api key"

## 4. Config + UX + docs

- [x] 4.1 Implement `providers` table resolution (`providers[provider].{api_key_env,base_url,model}` → legacy top-level → default) with `--model/-m` and `/model` on the active provider, and verify per-provider override + unknown-provider fallback scenarios
- [x] 4.2 Update `README.md` (provider setup: env vars, base URLs, models) and `docs/tech-spec.md` (resolve Anthropic/Google deferred item), and verify `openspec validate --change finish-llm-providers` passes
