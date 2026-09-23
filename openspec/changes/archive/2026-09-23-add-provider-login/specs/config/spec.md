# Spec Delta

## MODIFIED Requirements

### Requirement: API key from env
The credential for the active provider SHALL be resolved in this order: stored OAuth access token from `~/.tether/auth.json` when present and unexpired (refreshing once when expired and a refresh token exists), then stored `kind = "api_key"` entry, then `cfg.providers[cfg.provider].api_key_env` when set, otherwise the legacy top-level `cfg.api_key_env` (default OPENAI_API_KEY); missing key SHALL yield the empty string, not an error. The resolved variable name is the only env var read when the env path is taken. The store SHALL NOT be required: absence behaves exactly as today's env-only resolution.

#### Scenario: Custom env var name
- **WHEN** `api_key_env = "ANTHROPIC_API_KEY"`
- **THEN** the key is read from that variable when no stored credential applies

#### Scenario: Per-provider env resolution
- **WHEN** `provider = "gemini"` and `providers.gemini.api_key_env = "GEMINI_API_KEY"`
- **THEN** the key is read from `GEMINI_API_KEY` even when top-level `api_key_env` is `OPENAI_API_KEY`

#### Scenario: Stored token wins over env
- **WHEN** `auth.json` holds an unexpired oauth token for anthropic and env also has a key
- **THEN** requests use the stored token

#### Scenario: Store unreadable
- **WHEN** `auth.json` exists but is corrupt JSON
- **THEN** resolution falls back to env (or empty) without failing the session
