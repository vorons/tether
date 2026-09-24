# Design

## Context

See proposal.md (Why). Current state: `api.lua` `PROVIDERS` maps 3 ids → 3 modules 1:1; `header_lines(api_key)` takes only the key; `config.lua` defaults hold 3 presets; `ui.lua` `KNOWN_PROVIDERS` is a hardcoded triple; `static_models()` per module. Reference: pi `packages/ai/src/providers/*` (41 providers, 8 wire impls), `provider-attribution.ts`, `github-copilot-headers.ts`, `opencode-headers.ts`, `cloudflare-{auth,stream}.ts`, `env-api-keys.ts` (cloned to `/tmp/opencode/pi` during research).

Constraints: single binary, no new runtime deps (Lua 5.4 + vendored libcurl/mbedTLS only); key never in argv (mode-600 header file); canonical events unchanged; `agent.lua` untouched; embed order (provider modules before `api`).

## Goals / Non-Goals

**Goals:**
- 1 registry + 1 catalog table drive dispatch, config defaults, picker, and store keys.
- Tier-A = pure data (no new modules); Tier-B = isolated adapters behind the existing interface.
- Pi header quirks reproduced exactly where required for function (opencode session, copilot, cloudflare), attribution excluded per decision.

**Non-Goals:**
- Static model catalogs for presets (live `/models` only).
- Attribution/telemetry headers.
- Image/vision payload support beyond Copilot's vision-request flag.
- Radius `refreshModels`/persisted catalog (live `/v1/config` per session is enough for v1).

## Decisions

1. **Alias = `{ wire = "<module>", ...preset }`, not module-per-provider.** `provider_of(cfg)` resolves catalog id → wire module, returns `(id, module)`. Alternative (thin `deepseek.lua` re-exporting openai) rejected: ~35 near-empty files + embed rows for zero behavior.
2. **`header_lines(api_key, ctx)` — optional 2nd arg.** `ctx = { session_id = cfg._session_id, provider = id, messages = messages }`. Existing 3 modules ignore it (backward compatible); `api.lua` always passes it. Copilot needs message roles (X-Initiator) — `http_request` already holds `messages`. Alternative (per-preset hook in api.lua) rejected: keeps header logic in the wire layer where pi puts it.
3. **Extra headers live in the catalog entry** (`extra_headers` static + `auth_headers_override` for cloudflare's Authorization-suppression), applied by the wire module, not the transport. Keeps `api.lua` provider-blind.
4. **Cloudflare/AWS/Vertex multi-env via stored `env` object + ambient fallback** (mirrors pi `resolveCloudflareEnv` per-field merge). No new config keys: values come from `auth.json` entry `env` or process env; `config.api_key()` stays single-var for simple providers, gains a `config.provider_env(id)` helper for compound ones.
5. **Bedrock: bearer-first, SigV4 via vendored mbedTLS SHA256/HMAC.** SigV4 signing in Lua (~150 lines: canonical request, `AWS4-HMAC-SHA256`) reuses mbedTLS primitives already linked; needs one new C binding (`tether.hmac_sha256` or `tether.sha256`) — the single host-surface addition. Alternative (shell `aws` CLI) rejected: external dep + argv leak.
6. **Vertex ADC: file-read + OAuth2 token exchange over existing transport** (no JWT signing in v1 — service-account JWT deferred; ADC user creds use refresh_token exchange, GCE metadata + workload identity documented as unsupported). API-key path works fully.
7. **Radius/Codex: minimal viable.** Radius = `pi-messages`-shaped POST to gateway `baseUrl` with live `/v1/config` catalog per session (no persist); Codex = OAuth + Responses-shaped stream to `chatgpt.com/backend-api`. Both behind the canonical-event wall; quirks fixed post-merge from live traffic.
8. **`KNOWN_PROVIDERS` deleted; picker iterates catalog keys.** Single source of truth; sorted with the big-3 first for familiarity.
9. **Tier-B modules embedded (6 new rows); Tier-A adds zero build surface.** `mods[]` order preserved (new provider modules alongside existing three, before `api`).

## Risks / Trade-offs

- [Risk] SigV4 bugs are silent 403s → Mitigation: unit-test signer against AWS published test vectors in `lua_tests.lua` before any live call.
- [Risk] Catalog table (~40 entries) bloats `config.lua` → Mitigation: generated `providers/catalog.lua` from a compact data file; config requires it (still one embed row, no C change for Tier-A).
- [Risk] Copilot/OpenCode header drift (pi pins `Editor-Version`, session semantics) → Mitigation: headers versioned in one place with pi commit-hash comment; live smoke test per preset in tasks.
- [Risk] `header_lines` signature change breaks third-party/dev modules → Mitigation: 2nd arg optional; old single-arg modules keep working.
- [Risk] 40-entry picker overwhelms palette → Mitigation: existing fuzzy filter already handles it; big-3 pinned first.

## Migration Plan

Purely additive: existing configs (3 providers, top-level keys) resolve identically; unknown-provider fallback unchanged. Rollback = revert (no data migration; new `auth.json` entries are inert to old binaries). Docs (README provider table, design.md §5/§10) ship in the same change.

## Open Questions

- None blocking. Live smoke tests need real keys per provider (maintainer-run, not CI).
