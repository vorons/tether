# Spec Delta: api-client

## MODIFIED Requirements

### Requirement: SSE streaming request
The client SHALL select a provider adapter by `cfg.provider` (any catalog id, default `openai`) and POST the provider-specific streaming request: OpenAI-compatible `{"model":..., "messages":..., "stream":true}` JSON to `<base_url>/chat/completions`; Anthropic `{"model":..., "messages":..., "stream":true, "tools":..., "max_tokens":...}` JSON to `<base_url>/v1/messages`; Gemini `{"contents":..., "tools":...}` JSON to `<base_url>/v1beta/models/<model>:streamGenerateContent` (SSE) with REST `generateContent` fallback. Catalog entries whose wire is `openai`, `anthropic`, or `gemini` reuse that wire module with the entry's `base_url` (alias — no new adapter). The request SHALL be issued by the in-process HTTP client (vendored libcurl + mbedTLS): the body is written to a temp file and handed to the client as a file handle, so it never appears in a process argv and no `curl` subprocess is spawned. An empty line in the stream is an event boundary, not EOF; parsing SHALL continue after it. Unknown `cfg.provider` values SHALL fall back to `openai` with a stderr warning.

#### Scenario: Multi-event stream
- **WHEN** the stream contains two `data:` events separated by an
  empty line
- **THEN** both events are parsed and their deltas forwarded

#### Scenario: Unknown provider falls back
- **WHEN** `cfg.provider` is `"azure"` (unknown)
- **THEN** the OpenAI-compatible adapter is used and a stderr warning names the unknown value

#### Scenario: In-process transport
- **WHEN** the agent calls `api.stream(cfg, key, messages, on_event)`
- **THEN** the request is issued through the in-process HTTP client (no `curl` process) and SSE events reach `on_event` in stream order

#### Scenario: Alias preset streams
- **WHEN** `cfg.provider` is `"deepseek"` with no user override
- **THEN** the OpenAI-compatible request is POSTed to `https://api.deepseek.com/chat/completions`

### Requirement: Model listing
The client SHALL expose, per provider, a static fallback model list and a live listing that uses the provider's auth mechanism and extracts model ids. OpenAI-compatible live listing GETs `<base_url>/models` with the auth header file; Anthropic live listing GETs `<base_url>/v1/models` with `x-api-key` + `anthropic-version` headers; Gemini live listing GETs `<base_url>/v1beta/models?key=...` and extracts `name` fields. Live listing without a key SHALL return the error "no api key". The static OpenAI fallback keeps the existing 12 entries (gpt-4o-mini ... qwen-plus); Anthropic fallback lists current Claude models; Gemini fallback lists current Gemini models. Catalog presets added by this change (all non-`openai`/`anthropic`/`gemini` ids) SHALL have an empty static fallback: `/model` shows the live list, and an empty/unreachable list with no fallback. Tier-B adapters define their own live listing (Bedrock `ListFoundationModels`/Converse discovery, Vertex `models.list`, Azure deployments path, Cloudflare per-gateway catalog, Radius `/v1/config` catalog, Codex models endpoint).

#### Scenario: Live list empty
- **WHEN** `/models` returns a body with no `id` fields
- **THEN** the result is nil with reason "empty model list"

#### Scenario: Per-provider fallback
- **WHEN** the active provider is `anthropic` and the live listing fails
- **THEN** the static Claude list is returned, not the OpenAI list

#### Scenario: Preset has no static list
- **WHEN** the active provider is `groq` and the live listing fails
- **THEN** the model list is empty (no fallback entries)

> `/model` falls back to the static list of the *active* provider (the
> OpenAI fallback is the fixed 12-entry set); `cfg.model` remains the
> direct control for pinning a model (README notes this). design.md
> §6.8 now documents the same behavior.

## ADDED Requirements

### Requirement: Model list caching

`/model` SHALL serve a fresh disk cache (`~/.tether/models_cache.json`, TTL 4h) with zero network. Otherwise the stale cache (or static list) is shown immediately and one background fetch (`tether.fetch_bg`, forked child, 20s cap) refreshes it; the open palette rebuilds when the fetch lands, otherwise the next open picks it up. Without background fetch support the fallback is a single sync attempt capped at 5s. `checked_at` persists on every attempt so a dead endpoint blocks at most once per TTL, not per open. The timeout argument of the live listing defaults to 30s for other callers.

#### Scenario: Fresh cache is instant

- **WHEN** the cache for the active provider is fresh
- **THEN** no HTTP request is issued and the cached list is shown

#### Scenario: Stale cache shows instantly, refresh lands in background

- **WHEN** the cache is stale and a key is present
- **THEN** the stale list appears with no blocking request and exactly one background fetch runs

#### Scenario: Dead endpoint blocks once

- **WHEN** the live attempt fails and no cache exists
- **THEN** the static list is shown and the next open within TTL issues no request

### Requirement: Per-preset extra headers

The client SHALL append catalog `extra_headers` and provider-required dynamic headers to every request of a preset, after the auth header and before any user override. Required cases (from pi sources): `opencode`/`opencode-go` SHALL send `x-opencode-session: <session id>` (request fails without it); `github-copilot` SHALL send `X-Initiator` (`user`|`agent` by last message role), `Openai-Intent: conversation-edits`, and `Copilot-Vision-Request: true` when the history carries images; `cloudflare-ai-gateway` SHALL send `cf-aig-authorization: Bearer <key>` and SHALL NOT send `Authorization` or `x-api-key`. No attribution headers SHALL be sent (`HTTP-Referer`, `X-Title`, billing/invoke-origin, client User-Agent overrides). The session id source is `cfg._session_id`; when unset, `x-opencode-session` SHALL be omitted (not sent empty).

#### Scenario: OpenCode session routing

- **WHEN** `provider = "opencode"` and `cfg._session_id` is set
- **THEN** the request carries `x-opencode-session` with that value

#### Scenario: Cloudflare gateway auth shape

- **WHEN** `provider = "cloudflare-ai-gateway"`
- **THEN** the header file carries `cf-aig-authorization` and no `Authorization` line

#### Scenario: No attribution leakage

- **WHEN** any preset request is in flight
- **THEN** no `HTTP-Referer`, `X-Title`, or billing-origin header is present

### Requirement: Tier-B adapters emit canonical events

Each Tier-B adapter (amazon-bedrock, google-vertex, azure-openai full, cloudflare-ai-gateway URL templating, radius, openai-codex) SHALL emit only the existing canonical event set (`text_delta`, `reasoning_delta`, `tool_call_start`, `tool_call_delta` raw, `usage`, `done` with mapped stop reason) and report failures as classified failure records — never provider-specific events. `agent.lua` SHALL NOT branch on these providers.

#### Scenario: Bedrock tool call round-trip

- **WHEN** a Bedrock Converse stream carries `contentBlockDelta` tool-use input JSON
- **THEN** `tool_call_start` plus raw `tool_call_delta` fragments are emitted and the agent parses args exactly once

#### Scenario: Azure resource URL normalization

- **WHEN** the Azure base URL is a resource root (`*.ai.azure.com`, `*.cognitiveservices.azure.com`, `*.openai.azure.com`)
- **THEN** requests target the normalized OpenAI API path for that resource
