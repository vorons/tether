# Tasks

## 1. Token store

- [x] 1.1 Add `auth.lua`: load/save `~/.tether/auth.json`, create-empty + fchmod 0600 before write, tolerant read of missing/corrupt file; unit-test modes, corrupt fallback, per-provider get/set/delete
- [x] 1.2 Redaction helper for tokens in any logged/error strings; unit-test redaction

## 2. Resolution chain

- [x] 2.1 Extend `config.api_key` (or `credentials`) with order: unexpired OAuth → expired+refresh (eager) → stored api_key → env → ""; unit-test every branch including corrupt store
- [x] 2.2 Ensure TUI startup and `--print` both use the same resolver; grep call sites, adjust if any bypasses
- [x] 2.3 OAuth bearer header still via mode-600 header file; unit-test header content for oauth vs x-api-key vs gemini query

## 3. Login / logout commands

- [x] 3.1 Register `/login` `/logout` in palette + command dispatch; unknown provider → error banner; print-mode rejects interactive login; unit-test command parsing
- [x] 3.2 Implement paste-based flow: prompt for API key or access token, store as appropriate kind, confirm without echoing secret; unit-test store update path with stubbed prompt
- [x] 3.3 Provider exchange hooks (openai/anthropic/gemini): authorize URL print + best-effort browser open + code/token exchange via HTTP client; unit-test exchange request shape with stubbed HTTP
- [x] 3.4 `/logout` removes provider entry, confirmation line has no secrets; unit-test
- [x] 3.5 Bare `/login` opens provider picker in the shared palette (`palette_mode = "login"`, same mechanism as `/copy` — no full-screen overlay, no silent active-provider default); unit-test picker list + Enter → login secret mode (T155)
- [x] 3.6 Login secret mode: masked secret in `S.login_secret.buf`, never `S.input` / transcript; Esc cancels without store; unit-test paint + isolation (T153/T156)

## 4. Refresh on 401

- [x] 4.1 On classified auth failure with refresh_token: one refresh, persist, retry attempt once; unit-test success and refresh-failure → permanent error suggesting `/login`
- [x] 4.2 Confirm refresh does not loop and does not journal tokens

## 5. Verification and docs

- [x] 5.1 `make test` green
- [x] 5.2 Manual: bare `/login` shows provider picker palette (not overlay); login secret mode masks secret; login stores 0600 file; request uses token; logout clears; env-only path unchanged when no store; `--print` rejects `/login` `/logout` with a clear error
- [x] 5.3 README/config docs: auth.json location, `/login` `/logout`, security note (backups, 0600)
