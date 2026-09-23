# Spec Delta

## MODIFIED Requirements

### Requirement: Session commands transcript semantics
- `/new` SHALL drop both the agent history and the visible transcript, leaving only a new-session banner.
- `/clear` SHALL clear the transcript display only; the agent keeps its history, so the next turn still sees full context.
- `/compact` SHALL force an immediate compaction (ignoring the threshold) and append a summary line to the transcript. Optional free text after `/compact` SHALL be passed to the summary request as focus instructions. On LLM success the row SHALL show the generated summary (or its stable marker when empty); on fallback the existing `── summary ──` row behavior applies.
- `/login [provider]` and `/logout [provider]` SHALL be registered as built-in slash commands: `/login` with a named provider starts the login flow for that provider; `/login` with no argument opens a provider picker in the shared palette (same mechanism as the slash menu / `/copy` — never a full-screen overlay, never a silent default). Selecting a provider enters login secret mode (`S.login_secret = { buf }`): the secret buffer owns the keyboard while open, is masked on screen, and never appears in `S.input` or a transcript row (see Login secret mode). `/logout` clears the stored credential for the named or active provider. Neither command SHALL print token material to the transcript. Unknown provider names SHALL show an error banner. The palette listing SHALL include both commands with short descriptions.

#### Scenario: New session starts clean
- **WHEN** the user runs `/new` with a non-empty transcript
- **THEN** only the new-session banner remains on screen

#### Scenario: Clear keeps agent context
- **WHEN** the user runs `/clear` and then sends a message
- **THEN** the agent answers with full prior history while the screen shows only the new exchange

#### Scenario: Login appears in palette
- **WHEN** the user opens the slash palette
- **THEN** `/login` and `/logout` are listed among the built-in commands

#### Scenario: Logout line has no secrets
- **WHEN** the user runs `/logout`
- **THEN** a confirmation line appears and contains no token, refresh token, or key text

#### Scenario: Compact with focus instructions
- **WHEN** the user runs `/compact keep the API contract details`
- **THEN** compaction runs immediately, the summary request includes that focus text, and the transcript gains a summary row

#### Scenario: Compact reports fallback
- **WHEN** `/compact` runs and the summary request fails
- **THEN** the transcript still gains a `── summary ──` row (truncation fallback) and no error banner is raised for the summary failure alone
