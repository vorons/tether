# Spec Delta: provider-catalog

## Purpose

The provider catalog maps every supported provider id to its wire protocol, default endpoint, credential source, and default model, so adding a pi-parity provider is a data entry plus (only for new wire protocols) an adapter module.

## ADDED Requirements

### Requirement: Catalog entries

Each catalog entry SHALL define: provider `id` (kebab-case, matching pi ids where the provider exists in pi), `wire` (one of `openai` | `anthropic` | `gemini` | adapter module name for Tier-B), default `base_url`, `api_key_env`, default `model`, and optional `extra_headers` (static name/value pairs).

#### Scenario: Preset resolves without user config

- **WHEN** `provider = "deepseek"` with no `providers.deepseek` table in user config
- **THEN** requests go to `https://api.deepseek.com` with `DEEPSEEK_API_KEY` over the OpenAI-compatible wire

#### Scenario: User override wins

- **WHEN** the user sets `providers.deepseek.base_url`
- **THEN** that URL is used instead of the catalog default

### Requirement: Alias resolution

A catalog entry whose `wire` is `openai`, `anthropic`, or `gemini` SHALL reuse that wire module with the entry's `base_url` — no new adapter module, no new embed row, no new C registration. `provider_of` SHALL return the catalog id (not the wire name) so logs, auth store keys, and warnings name the provider the user configured.

#### Scenario: Alias keeps provider identity

- **WHEN** `provider = "groq"`
- **THEN** the request uses the OpenAI-compatible module against `https://api.groq.com/openai/v1`, and an unknown-provider warning never fires for `groq`

#### Scenario: Alias fallback chain unchanged

- **WHEN** `cfg.provider` names no catalog entry
- **THEN** behavior matches the existing unknown-provider fallback (stderr warning + `openai`)

### Requirement: Catalog coverage

The catalog SHALL contain an entry for every pi builtin provider that maps to a supported wire protocol (Tier-A, ~35 ids), plus Tier-B adapter entries (amazon-bedrock, google-vertex, azure-openai, cloudflare-ai-gateway, radius, openai-codex). The `/login` picker list SHALL be derived from the catalog keys, so the picker and the dispatcher can never disagree.

#### Scenario: Picker matches dispatcher

- **WHEN** a provider id is added to the catalog
- **THEN** it appears in the `/login` picker with no separate list edit
