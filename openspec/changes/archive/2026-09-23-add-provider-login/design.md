# Design

## Context

Auth today is env-only: `config.api_key(cfg)` reads `os.getenv(api_key_env)`. HTTP auth travels through a mode-600 temp header file (`api.lua` `header_file`) — never argv. Providers: OpenAI `Authorization: Bearer`, Anthropic `x-api-key`, Gemini `?key=` query. There is no token store, no `/login`, no refresh. Retry classifies invalid-key as permanent (stop). Single-binary constraint: no Node, no external OAuth SDK; HTTP is in-process libcurl. See proposal.md for motivation.

## Goals / Non-Goals

**Goals:**
- `/login` `/logout` for openai, anthropic, gemini (subscription/OAuth where the provider supports a terminal flow; API-key paste as universal fallback).
- Secure `~/.tether/auth.json` (0600), resolution chain, single refresh on 401.
- Same resolution for TUI and `--print`.

**Non-Goals:**
- OS keychain / secret-service.
- Multiple accounts per provider.
- Enterprise SSO / device-code standards beyond what each flow needs.
- Storing tokens in config.lua (user-editable — keep secrets out of it).

## Decisions

1. **JSON file store `~/.tether/auth.json` with 0600-from-creation**  
   Mirrors `auto_approve.lua` as a machine-managed side file but JSON for structured expiry. Write via create-empty → `tether.fchmod(0600)` → rewrite (same pattern as header_file). Alternatives: single file per provider (more files, same risk); Lua table like auto_approve (harder to evolve). Atomic write: temp in same dir + rename if host allows; else truncate-write is acceptable given single process.

2. **Terminal-feasible flows: prefer device/manual paste; browser open + paste redirect as secondary**  
   No embedded HTTP callback server in v1 (would need host listen primitive or busy-loop on stdin — fragile). Credential entry uses login secret mode (`S.login_secret.buf`, masked on screen — never `S.input`, never an overlay): the authorize URL is shown in the transcript/diagnostic line, best-effort open, the secret is typed/pasted into the secret buffer, then exchanged via existing HTTP client. Bare `/login` opens the provider picker **in the shared palette** (`palette_mode = "login"`, same mechanism as the slash menu and `/copy` — `S._in_login_palette` keeps `palette_sync` from overwriting it) instead of a full-screen overlay or a silent default to the active provider. Each provider adapter gets `login_flow()` / `token_exchange()` hooks so OAuth details stay out of `auth.lua` core. Fallback: user pastes an existing API key → stored as `kind=api_key` (still 0600) so `/login` is one door for both.

3. **Resolution lives in `config.credentials(cfg)` (or extends `config.api_key`)**  
   Returns `{ token, kind, provider }` or string as today for compatibility. `api_key` becomes a thin wrapper returning the string so call sites (`ui`, `app`, `commands.list_models`) keep working. Refresh is explicit: either eager inside resolution when `expires_at` past, or reactive on 401 — **do both**: eager when expiry known, reactive once on auth-classified failure in the agent retry seam.

4. **Refresh on 401 hooks into retry classification**  
   When `retry.classify` says invalid key/auth AND store has refresh_token → run refresh (one HTTP call), persist, retry same attempt once without incrementing a user-visible "retry wait" (or count as attempt 0). If refresh fails → permanent failure with `/login` hint. Alternative: handle only in UI — rejected (`--print` needs it too).

5. **Gemini OAuth vs API key**  
   Gemini subscription auth is less uniform than OpenAI/Anthropic; first cut may complete openai+anthropic OAuth and accept pasted Gemini API key / OAuth access token via the same paste path. Spec allows `kind=api_key` for all three. Provider-specific OAuth endpoints documented in code comments during apply; if a provider has no stable public terminal flow, paste is the supported path — still meets `/login` UX.

6. **Never leak**  
   Tokens excluded from `slog` journal, `/copy`, debug log, error banner bodies (redact `access_token` / `refresh_token` / `Authorization` in any raw HTTP error echo). Secrets are entered only through login secret mode — never `S.input`, never a transcript row; the painted frame shows stars only.

## Risks / Trade-offs

- [Provider OAuth flows change or are undocumented] → Isolate per-provider; paste-API-key fallback always works; flows are best-effort.
- [Refresh race with two processes] → Accept last-writer-wins; single interactive session is the norm.
- [Secrets in JSON on disk] → 0600 + home dir; document backup risk in README security note (task).
- [401 misclassified as permanent before refresh hook] → Order: refresh check runs before permanent stop in agent attempt failure path.

## Migration Plan

1. Store + resolution (no flow yet) + tests — pure additive, env-only users unaffected.
2. `/login` paste path + `/logout` + palette.
3. Provider OAuth exchange paths behind the same command.
4. Reactive refresh on 401.
5. Docs: README/config security note.

## Open Questions

- None blocking. Exact OAuth endpoints/client ids per provider are implementation detail discovered at apply time; if a provider requires a registered client id, use the project's published id or document user-supplied client id in config (`providers.<p>.oauth_client_id`) — additive config key, does not change resolution spec.
