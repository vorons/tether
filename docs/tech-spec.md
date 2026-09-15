# tether — tech-spec

## Architecture

Two layers, one binary:

```
C host (src/host)          Lua core (src/tether)
─────────────────          ────────────────────
termios / raw mode         app, ui, agent, api
fork/exec/pipe (spawn)     tools, session, config
curl subprocess (SSE)      markdown-lite, overlays
Lua embed (static arrays)
```

C host exposes a narrow syscall API to Lua. All agent logic is Lua.

## Data flow

**Chat stream:**
`agent` builds request → `api.stream` → C host runs `curl` subprocess → SSE parsed → canonical events (`text_delta`, `reasoning_delta`, `tool_call_*`, `usage`, `done`, `error`) → `ui` renders transcript.

**Tool call:**
LLM returns tool_call → agent checks policy (workspace boundary, confirm rules) → `tools.*` executes → result as tool_result → next LLM request.

**Session:**
JSONL at `~/.tether/sessions/<id>.jsonl`. One event per line. `-r` picks latest by mtime matching `meta.workspace`.

## Key decisions

- **Single binary target (M6):** Lua modules embedded as C arrays via `tools/embed.lua` generator.
- **OpenAI-compatible first:** Anthropic/Google adapters share the same `stream()`/`list_models()` contract.
- **Retries:** 3 attempts, exponential backoff (0.5/1/2s), only on 429/5xx/network. No retry on 4xx.
- **Confirmation policy:** `write`, `patch`, `run` outside workspace require user confirmation. `[A] always` persists to `~/.tether/config.lua` `auto_approve`.
- **Token budget:** `context.max_tokens` (default 32768); summarize at 70% via `context.summarize_at`.
- **UI regions:** transcript (flex) / error banner / input / palette / hint / status line. No header.

## Deferred (post-MVP)

Anthropic/Google adapters, PTY, background tasks, git integration, LSP, multi-session, themes, vector memory, drag selection.
