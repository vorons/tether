# Tasks

## 1. Catalog + alias dispatch

- [x] 1.1 Add `src/tether/providers/catalog.lua` with all Tier-A presets (id → wire, base_url, api_key_env, model, extra_headers) sourced from pi providers/* + env-api-keys.ts; verify with `luac -p` and a lua one-liner dumping entry count
- [x] 1.2 Rework `api.lua` `PROVIDERS` to alias resolution returning `(id, module)`; unknown id keeps stderr-warning + openai fallback; verify `M._provider_of` returns `("groq", openai_module)` and warns once for unknown in `tests/lua_tests.lua`
- [x] 1.3 Extend `header_lines(api_key, ctx)` plumbing in `api.lua` (`ctx = { session_id, provider, messages }`); existing 3 modules ignore the arg; verify existing header tests pass unchanged
- [x] 1.4 Implement per-preset extra headers: `x-opencode-session` (omit when no session), Copilot `X-Initiator`/`Openai-Intent`/`Copilot-Vision-Request`, cloudflare `cf-aig-authorization` with Authorization suppression; verify header-file contents per preset in `tests/lua_tests.lua`

## 2. Config + picker + models

- [x] 2.1 Wire catalog defaults into `config.lua` (all ids: api_key_env/base_url/model); user `providers.<id>` overrides win; verify resolution for 3 sample presets (deepseek, kimi-coding, xiaomi-token-plan-sgp) in `tests/lua_tests.lua`
- [x] 2.2 Replace `KNOWN_PROVIDERS` in `ui.lua` with sorted catalog keys (openai/anthropic/gemini first); verify `/login` picker lists all ids and unknown name still shows error banner
- [x] 2.3 Empty `static_models()` for presets (live `/models` only); verify `/model` shows live list and empty when unreachable, and the 3 legacy providers keep fallbacks
- [x] 2.4 Model-list cache (pi-style): fresh cache served with zero network, stale refresh capped at 5s, checked_at persisted on failure; verify no-network hit + single attempt + no hammering in `tests/lua_tests.lua` (T169)
- [x] 2.5 Background model refresh: `tether.fetch_bg` (fork + same curl path, @file headers unlinked pre-fork, SIGCHLD auto-reap), instant stale/static display, live palette rebuild on land; verify spawn/poll/settle in `tests/lua_tests.lua` (T170) + e2e pty (local server, blackhole)

## 3. Provider-auth: flows + multi-source

- [x] 3.1 Device/OAuth login flows (copilot, codex, anthropic, meta, kimi, xai, openrouter, radius) via `login_flow`/`token_exchange` with config-sourced endpoints + API-key-paste fallback; verify store write + masked secret for one OAuth + one key flow in tests
- [x] 3.2 Multi-source resolution: stored `env` + ambient merge (Cloudflare trio, Vertex key/ADC+project/location, Bedrock bearer/profile/chain, `ANTHROPIC_AUTH_TOKEN` Bearer); verify per-field merge + partial-credential refusal in `tests/lua_tests.lua`

## 4. Tier-B adapters

- [x] 4.1 `azure-openai.lua`: resource-URL normalization + `api-key` header + deployments path; verify URL mapping for the 3 resource-root suffixes in tests
- [x] 4.2 `amazon-bedrock.lua`: Converse stream + bearer path + SigV4 signer (new `tether.sha256/hmac` binding); verify signer against AWS test vectors in `tests/lua_tests.lua` before any live call
- [x] 4.3 `google-vertex.lua`: ADC/API-key + project/location resolution, canonical events only; verify header/URL construction in tests
- [x] 4.4 `cloudflare-ai-gateway.lua` (URL templates + gateway auth), `radius.lua` (live `/v1/config` catalog), `openai-codex.lua` (OAuth + backend stream); verify each emits canonical events for a canned stream in tests
- [x] 4.5 Build wiring for the 6 Tier-B modules only (Makefile `LUA_MODS`/embed-args/`luac -p`, `main.c` `mods[]` order); verify `make test` passes and `grep -c provider_bedrock_lua src/host/embed.c` > 0

## 5. Docs + live verification

- [x] 5.1 README provider table (id, env vars, auth notes) + `docs/design.md` §5/§10 updates; verify tables match catalog keys via a grep-count check
- [ ] 5.2 Live smoke tests (maintainer keys): one chat turn + `/model` list per wire family (openai-alias, anthropic-alias, gemini, copilot, opencode, azure, bedrock, vertex); verify canonical events + no key in argv per attempt
