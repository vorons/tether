# provider-auth Specification

## Purpose
OAuth login for subscription providers: `/login` `/logout`, secure token storage, credential resolution order, and refresh-on-401 behavior shared by TUI and print mode.

## Requirements

### Requirement: Token store file
Credentials SHALL be stored in `~/.tether/auth.json`. The file SHALL be created with mode 0600 before any secret is written (same discipline as the API header temp file). The file SHALL hold a JSON object keyed by provider id (any catalog id), each value an object with at least `kind` (`"oauth"` or `"api_key"`), `access_token`, and optionally `refresh_token`, `expires_at` (unix seconds), `token_type`, `scope`, and an `env` object for provider-scoped extra values (Cloudflare account/gateway ids, Vertex project/location, AWS profile). Tokens SHALL NOT be written to the session journal, transcript rows, debug log, or argv. `/logout` SHALL remove only the named provider's entry (or the active provider when unnamed). A missing or unreadable store SHALL contribute no credentials and SHALL NOT fail startup.

#### Scenario: Store created private
- **WHEN** `/login` completes successfully for the first time
- **THEN** `~/.tether/auth.json` exists with mode 0600 and holds the provider entry

#### Scenario: Missing store
- **WHEN** the file does not exist
- **THEN** resolution falls through to env and the session starts normally

#### Scenario: Logout removes one provider
- **WHEN** the user runs `/logout anthropic` with entries for openai and anthropic
- **THEN** only the anthropic entry is removed

### Requirement: Credential resolution order
For the active provider, the client SHALL resolve credentials in this order: (1) a stored OAuth access token that is not expired; (2) if expired and `refresh_token` exists, one refresh attempt, then the new access token (persisted); (3) stored `kind = "api_key"` entry if present; (4) env `api_key_env` per existing config rules; (5) empty string. Resolution SHALL be a single function used by both TUI and `--print`. The resolved value SHALL flow into the existing mode-600 header file path; OAuth bearer SHALL use `Authorization: Bearer <token>` (or the provider's equivalent) without changing the never-in-argv rule.

#### Scenario: Valid OAuth preferred over env
- **WHEN** `auth.json` has an unexpired oauth token for the active provider and the env var is also set
- **THEN** requests use the stored token

#### Scenario: Expired token refreshes once
- **WHEN** the stored access token is expired and a refresh token exists
- **THEN** one refresh request runs, the store is updated, and the request uses the new token

#### Scenario: No store falls back to env
- **WHEN** `auth.json` has no entry for the active provider
- **THEN** behavior matches the pre-change env-only resolution

### Requirement: Login and logout commands
`/login [provider]` SHALL start the login flow for the given provider; when the provider is omitted the TUI SHALL open a provider picker in the shared palette (`palette_mode = "login"`, same mechanism as the slash menu — never a full-screen overlay, never a silent default to the active provider) listing all catalog ids. Unknown provider names SHALL show an error banner and not start a flow. Selecting a provider SHALL enter login secret mode (`S.login_secret = { buf = "" }` — a dedicated buffer, never `S.input`, never an overlay): the secret (API key, OAuth code, device code, or redirect URL) is typed or pasted into that buffer and masked on screen, never written to a transcript row. The flow SHALL guide the user through a terminal-feasible path (device/manual paste or browser open + pasted redirect), then persist tokens per the store rules. `/logout [provider]` SHALL clear the stored entry for the named or active provider when unnamed and confirm with a transcript/system line (no token material). Both commands SHALL appear in the slash palette with descriptions. In `--print` mode they SHALL be unavailable (no interactive flow) with a clear error — first cut: interactive-only, print mode errors.

#### Scenario: Login opens provider picker when omitted
- **WHEN** the user runs `/login` with no argument
- **THEN** the shared palette opens in `palette_mode = "login"` listing all catalog provider ids (not a full-screen overlay); selecting one enters login secret mode for that provider and the palette closes

#### Scenario: Login active provider
- **WHEN** the user runs `/login` with `provider = "anthropic"`
- **THEN** the anthropic flow starts and on success the store holds the token

#### Scenario: Secret stays out of chat input and transcript
- **WHEN** the user pastes an API key while login secret mode is open and presses Enter
- **THEN** the main chat input remains empty, no transcript row contains the key, and the store holds the credential

#### Scenario: Secret mode masks the secret
- **WHEN** a secret is entered while login secret mode is open
- **THEN** the painted frame shows only a mask (stars), never the plaintext secret

#### Scenario: Unknown provider
- **WHEN** the user runs `/login azure`
- **THEN** an error banner names the unknown provider and no flow starts

#### Scenario: Logout confirmation
- **WHEN** the user runs `/logout`
- **THEN** the active provider's stored entry is removed and a confirmation line appears without any token text

### Requirement: Refresh on auth failure
When a main-loop attempt fails with a classified invalid-key/auth failure and the active provider has a stored `refresh_token`, the agent SHALL attempt one refresh, update the store, and retry the attempt once with the new token. If refresh fails or there is no refresh token, the turn SHALL surface the original auth error with guidance to run `/login`. Refresh SHALL NOT consume more than one extra transport attempt and SHALL NOT loop.

#### Scenario: Refresh then success
- **WHEN** a 401 arrives with a valid refresh token
- **THEN** one refresh runs, the retry uses the new access token, and the turn continues without an `error` event for the first 401

#### Scenario: Refresh fails
- **WHEN** refresh is rejected
- **THEN** a single `error` event (or banner in TUI) mentions auth failure and suggests `/login`; no further refresh loops

### Requirement: Subscription OAuth login flows

Providers with subscription/OAuth access (github-copilot device flow, openai-codex, anthropic, meta, kimi-coding, xai, openrouter, radius) SHALL offer a terminal-feasible OAuth path through the existing `login_flow`/`token_exchange` hooks: authorize/device URL display (best-effort browser open), then paste of the redirect URL / device code / access token into login secret mode, then token exchange and store persist. OAuth app endpoints (authorize/token URLs, client ids) SHALL come from the provider's config table — never invented. When no OAuth app is configured for the provider, the flow SHALL degrade to API-key paste (existing behavior).

#### Scenario: Copilot device flow
- **WHEN** the user runs `/login github-copilot` with no stored credential
- **THEN** the flow shows the device URL + code and accepts the pasted verification result in secret mode

#### Scenario: No OAuth app falls back to key
- **WHEN** the provider has no OAuth endpoints in config
- **THEN** `/login <provider>` accepts an API-key paste exactly as today

### Requirement: Multi-source credential resolution

For providers needing more than one value, resolution SHALL merge per-field: stored `env` object first, then ambient process env. Cloudflare requires `CLOUDFLARE_API_KEY` + `CLOUDFLARE_ACCOUNT_ID` (+ `CLOUDFLARE_GATEWAY_ID` for the gateway); Vertex accepts `GOOGLE_CLOUD_API_KEY` or ADC (`GOOGLE_APPLICATION_CREDENTIALS` — both `authorized_user` and `service_account` forms — or `~/.config/gcloud/application_default_credentials.json`) + `GOOGLE_CLOUD_PROJECT` (+`GCLOUD_PROJECT`) + `GOOGLE_CLOUD_LOCATION`; Bedrock resolves ambient credentials in AWS SDK order — explicit static keys (`AWS_ACCESS_KEY_ID`+`AWS_SECRET_ACCESS_KEY`, +`AWS_SESSION_TOKEN`), then `AWS_PROFILE` (or the `default` profile; the stored-profile choice selects the credentials-file profile even when the process env is bare), then bearer `AWS_BEARER_TOKEN_BEDROCK` — and then ECS (`AWS_CONTAINER_CREDENTIALS_*`)/IRSA (`AWS_WEB_IDENTITY_TOKEN_FILE`). Anthropic SHALL additionally accept `ANTHROPIC_AUTH_TOKEN` as `Authorization: Bearer` and `ANTHROPIC_OAUTH_TOKEN` as api key. A missing required piece SHALL yield no credential (fall through to the next source), never a partial auth header.

#### Scenario: Cloudflare gateway needs all three
- **WHEN** only `CLOUDFLARE_API_KEY` is set for `cloudflare-ai-gateway`
- **THEN** resolution yields no credential until account and gateway ids are present

#### Scenario: Bedrock ambient chain
- **WHEN** `AWS_PROFILE` is set with no stored entry for `amazon-bedrock`
- **THEN** requests authenticate via that profile without copying secrets into the store
