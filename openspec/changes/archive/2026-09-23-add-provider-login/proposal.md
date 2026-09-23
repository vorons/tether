# Proposal

## Why

tether only supports env-var API keys (`api_key_env`). Subscription users (Claude Pro/Max, ChatGPT plan, Gemini advanced) expect a `/login` flow that stores refreshable OAuth tokens; today they must mint and export raw keys, and tokens cannot be refreshed when they expire.

## What Changes

- New slash commands **`/login [provider]`** and **`/logout [provider]`** (no arg → provider picker in the shared palette — same mechanism as the slash menu / `/copy`; secret entry is a masked dialog outside the chat input/transcript).
- **OAuth token store** at `~/.tether/auth.json` (created with mode 0600 before any secret is written): per-provider `{access_token, refresh_token?, expires_at?, token_type?, scope?}` plus a non-secret `kind` (`oauth` | `api_key`).
- **Credential resolution order** for the active provider: valid stored OAuth access token → refresh if expired (one refresh attempt, persist new tokens) → env `api_key_env` → empty string. Resolution stays in one place (`config.api_key` or a thin `config.credentials` helper) so TUI and `--print` share it.
- **First-cut flows** (all three providers):
  - Prefer a **local callback** or **device/manual paste** flow that works in a terminal without embedding a browser; if a provider only offers a browser flow, open the URL (best-effort `xdg-open`/`open`) and accept a pasted redirect/code.
  - Store whatever the provider returns; never print tokens to the transcript or logs.
- **`/logout`** removes the stored entry for the provider (and leaves env keys untouched).
- On a 401/invalid-key failure classified by `retry`, if a stored refresh token exists, refresh once and retry the attempt; if refresh fails, surface a clear error suggesting `/login`.
- Startup: if the active provider has a stored token that is expired and unrefreshable, warn on stderr (TUI: error banner on first paint) but still start.

## Capabilities

### New Capabilities

- `provider-auth`: login/logout commands, token store layout and permissions, resolution order, refresh-on-401, and failure UX.

### Modified Capabilities

- `config`: `api_key` resolution gains the credential chain (stored token before env); defaults unchanged when no store exists.
- `api-client`: auth header construction consumes the resolved credential (still via mode-600 header file — no argv leakage); a single refresh request may run before the normal attempt.
- `tui`: `/login` `/logout` registered in the palette; no token material in transcript rows.

## Impact

- Code: new `src/tether/auth.lua` (store + refresh + flow helpers), `src/tether/commands.lua` or `ui.lua` (slash handlers), `src/tether/config.lua` (resolution), `src/tether/api.lua` / `providers/*` (credential injection), `Makefile` `LUA_MODS` + embed regen.
- Storage: new machine-managed side file `~/.tether/auth.json` (document next to `auto_approve.lua`).
- Tests: unit tests for resolution order, 0600 creation, refresh success/failure paths (HTTP mocked via existing seams); no real network in tests.
- Security review required before merge: secrets never in argv, env dump, journal, or `/copy`.
- Out of scope for this change: multiple simultaneous accounts per provider, enterprise/SSO, keychain/secret-service integration (file store only).
