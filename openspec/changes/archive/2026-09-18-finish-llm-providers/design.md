# Design: finish-llm-providers

## Context

See `proposal.md` for motivation. Current state: `src/tether/api.lua` (~355 lines) is a single OpenAI-compatible client — request builder (`encode_messages`), SSE parser (`parse_sse_line`), transport (`http_request` via `tether.open_pipe` + curl), retry (`is_retryable_body`, `extract_retry_after`), key handling (`auth_header_file`). `src/tether/config.lua` hardcodes `provider = "openai"` with no dispatch. `agent.lua` consumes only canonical events and must not change. Design doc (`docs/design.md` §5) already fixes the adapter contract: `stream(request, on_event)` + `list_models()` with canonical events; this change fills it in for Anthropic and Gemini. Reference shapes: `erikarn/claude-lua` (Anthropic SSE: `message_start` / `content_block_start` / `content_block_delta[text_delta|input_json_delta]` / `content_block_stop` / `message_delta` / `message_stop`; stateless full-history sends; tool list on every call), `dotMavriQ/linea src/api/gemini.lua` (curl + temp body file, `generateContent` payload, `?key=` auth, `candidates[].content.parts[].text` extraction, error-first handling), `chutesai/e2ee-proxy` (one proxy speaking OpenAI + Claude Messages + Responses formats by translating to a canonical request — same dispatcher idea, mirrored here client-side).

Constraints: Lua 5.4, no `load()`, no new deps (only `curl` + C host pipes); key never in argv; `luac -p` + `tests/lua_tests.lua` + `make test` stay green; single-binary embed must include new modules.

## Goals / Non-Goals

**Goals:**
- `cfg.provider` dispatch with zero behavior change for existing OpenAI configs.
- Anthropic + Gemini adapters emitting byte-identical canonical events to the agent.
- Per-provider key/URL/model resolution with backward-compatible config.
- Shared transport (header/body temp files, curl pipe, retry, error surfacing) reused by all adapters.

**Non-Goals:**
- OpenAI Responses API, streaming tool schema negotiation, per-model reasoning toggles.
- PTY, OAuth/device flow, keychain storage, proxy support.
- Server-side format translation (e2ee-proxy direction) — this change is client-side only.

## Decisions

1. **Dispatcher + per-provider modules, not three clients.** `api.lua` keeps shared transport + `M.stream`/`M.list_models*` entry points and delegates to `providers/openai.lua`, `providers/anthropic.lua`, `providers/gemini.lua` by `cfg.provider` (fallback `openai` + stderr warning). Alternative: three top-level clients with `if provider` in agent — rejected, would leak provider branches into `agent.lua` and triple retry/key logic.
2. **Canonical events are the seam; history conversion lives in adapters.** Each provider exposes `build_request(messages, cfg)` + `parse_sse_line(line, on_event)` with the same raw-args rule (fragments stay escaped; `agent.parse_args` unescapes once). Alternative: normalize history once in `api.lua` — rejected, Anthropic (`tool_result`/`tool_use` blocks, required `max_tokens`) and Gemini (`contents/parts`, `functionCall/Response`, `model` role) shapes diverge too far from OpenAI messages.
3. **Reuse the curl-pipe transport verbatim.** URL/headers/request-file differ per adapter; the loop (`open_pipe` → `read_line`, empty-line = boundary, `pipe_eof`), temp-file lifecycle (600 header file, body file, remove on both paths), backoff 0.5/1/2s + `Retry-After`, and non-SSE error surfacing stay shared. Gemini `?key=` follows the linea pattern (key from file-sourced value into the URL string inside the transport, never logged); Anthropic uses `x-api-key` header file instead of `Authorization: Bearer`.
4. **Config: additive `providers` table, legacy keys as `openai` defaults.** Resolution order: `cfg.providers[provider].{api_key_env,base_url,model}` → top-level legacy → hardcoded default. No migration: old `config.lua` files parse unchanged. Alternative: break top-level keys into per-provider only — rejected, breaks every existing install.
5. **Model listing per provider, static fallbacks checked in.** Live: OpenAI/Anthropic `GET <base>/models` (or `/v1/models`) with header file; Gemini `GET <base>/v1beta/models?key=` parsing `name`. Static fallbacks stay small curated lists; `/model` picker groups by provider. Alternative: single merged list — rejected, invites selecting a Claude model on the OpenAI endpoint.

## Risks / Trade-offs

- [Risk] Anthropic `input_json_delta` fragments split UTF-8/escape sequences across chunks → Mitigation: keep fragments raw, assemble by `index`, single unescape in agent (already the M7/D2b rule); add index-matched assembly tests.
- [Risk] Gemini non-SSE `generateContent` fallback shape differs from SSE → Mitigation: fallback normalizes to the same `text_delta`/`tool_call_*`/`usage` emission before returning; spec scenario pins it.
- [Risk] `?key=` in URL visible in `ps` (curl argv) → Mitigation: build the URL inside the transport from the key read at request time, never log the command line; document that `ps` may show the URL while the header-file pattern cannot apply to query auth (Google convention); keep header-file for OpenAI/Anthropic.
- [Risk] Provider drift (new Claude/Gemini models, renamed endpoints) → Mitigation: `cfg.providers.<name>.base_url/model` overrides cover it without code changes; static lists are fallback only.
- [Trade-off] No Responses-API support: some OpenAI-only features (e.g. `reasoning_summary` passthrough beyond current `reasoning_delta`) stay unmapped on Gemini — accepted, canonical events already cover the agent's needs.

## Migration Plan

1. Land dispatcher + providers with OpenAI path byte-identical (existing tests unchanged).
2. Add Anthropic + Gemini adapters behind `provider` flag; docs (`README.md`, tech-spec deferred item) updated in the same change.
3. Rollback: set `provider = "openai"` (or delete the key) — legacy top-level keys restore exact old behavior; no data migration (sessions store plain messages).

## Open Questions

- None blocking specs/approach/tasks. Model-list curation (exact Claude/Gemini ids in static fallbacks) is finalized at implementation time against live `/models` output.
