# Proposal: expand-provider-catalog

## Why

`tether` speaks only 3 providers (`openai` | `anthropic` | `gemini`). Reference agent [pi](https://github.com/earendil-works/pi) (`packages/ai/src/providers`, 41 builtin providers) shows the same 3 wire protocols cover the whole market — plus 5 special cases (OAuth subscription flows, per-request session headers, alternate auth headers, Bedrock SigV4, Vertex ADC, Radius custom protocol). Users with DeepSeek/Groq/OpenRouter/Copilot/etc. keys must hand-craft `base_url` today; heavy providers are unreachable at all.

## What Changes

- **Alias registry in `api.lua`**: `PROVIDERS[name] = { module = <one of provider_openai|provider_anthropic|provider_gemini>, ... }` — N provider ids share 3 wire modules, zero new embed/C rows. `provider_of` first tries own module, then alias; unknown → `openai` + stderr warning (unchanged).
- **~35 Tier-A presets in `config.lua`** (base_url + api_key_env + default model each): deepseek, groq, cerebras, xai, openrouter, fireworks, together, baseten, nvidia, moonshotai(+cn), huggingface, zai(+cn), qwen-token-plan(+cn/+individual), xiaomi(+token-plan-cn/ams/sgp), ant-ling, mistral (openai-compat endpoint), meta, kimi-coding/minimax(+cn)/vercel-ai-gateway (anthropic-compat endpoints), github-copilot, azure-openai (chat-completions path), cloudflare-workers-ai, llama.cpp/ollama-style local (`llama` preset).
- **Per-preset extra headers** from pi sources, no attribution (per decision): `x-opencode-session` (+ routing) for `opencode`/`opencode-go` (required, else 4xx); Copilot `X-Initiator`/`Openai-Intent`/`Copilot-Vision-Request`; Cloudflare gateway `cf-aig-authorization` instead of `Authorization`; Anthropic-alias `ANTHROPIC_AUTH_TOKEN` → `Authorization: Bearer`. Header plumbing: `header_lines(api_key)` gains optional `extra`/`ctx` arg (`cfg._session_id` source); modules ignore unknown args (backward compatible).
- **Login flows (`provider-auth`)**: OAuth/device-flow hooks for subscription providers per pi (`auth/oauth/*`: github-copilot, openai-codex, anthropic, meta, kimi-coding, xai, openrouter) — generic device-code + paste-redirect paths through existing `login_flow`/`token_exchange` interface, endpoints from config (never invented); api-key login works for all presets via `/login` picker.
- **Tier-B new adapters** (own wire/auth): `amazon-bedrock` (Converse + SigV4 or bearer, ambient AWS chain), `google-vertex` (ADC/api-key + project/location), `azure-openai` full (resource URL normalization + `api-key` header), `cloudflare-ai-gateway` (`{account}/{gateway}` URL templates + `cf-aig-authorization`), `radius` (pi-messages-compatible minimal? — design decides: full custom stream vs documented defer), `openai-codex` (ChatGPT backend OAuth).
- **Models: live `/models` only** — no static catalogs for new providers (`static_models()` returns `{}`; `/model` picker shows live list, empty when unreachable). Existing 3 providers keep their static fallbacks.
- **`/login` picker (`KNOWN_PROVIDERS`)** grows to the full id list (~40); login secret buffer discipline unchanged.

## Capabilities

### New Capabilities

- `provider-catalog`: preset table (id → wire module alias + base_url + api_key_env + default model + extra headers) and alias resolution covering all pi Tier-A providers.

### Modified Capabilities

- `api-client`: alias dispatch (shared module, per-preset base_url/headers); `header_lines` extended signature for extra/session headers; live-`/models`-only for new presets; new Tier-B adapters (bedrock/vertex/azure-full/cloudflare-gateway/radius/codex) emitting canonical events.
- `config`: per-provider `api_key_env`/`base_url`/`model` defaults for all new ids; resolution order unchanged.
- `provider-auth`: device/OAuth login flows for subscription providers; auth.json keyed by new ids; multi-env credential support (Cloudflare account/gateway, Vertex project/location, AWS chain).
- `host`: no requirement change (existing "embed all sources" rule covers Tier-B modules); build rows (`LUA_MODS`, embed-args, `mods[]`, `luac -p`) are implementation detail.
- `tui`: `/login` picker lists all provider ids; `/model` shows live-only lists for presets.

## Impact

- Code: `src/tether/api.lua` (alias registry), `src/tether/config.lua` (preset table ~40 entries), `src/tether/providers/*.lua` (Tier-B adapters; Tier-A needs none), `src/tether/ui.lua` (`KNOWN_PROVIDERS`), `Makefile`/`main.c` (Tier-B rows only), `tests/lua_tests.lua` (alias resolution, header injection, per-preset defaults).
- Docs: `README.md` (provider table with env vars), `docs/design.md` §5/§10.
- No agent/transport/session contract changes; canonical events unchanged; existing 3 providers behave identically.
