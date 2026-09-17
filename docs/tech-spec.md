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
`agent` builds request → `api.stream` → C host runs `curl` subprocess → SSE parsed → canonical events (`text_delta`, `reasoning_delta`, `tool_call_*`, `usage`, `done`, `error`, `retry`, `context_compressed`) → `ui` renders transcript.

**Print mode:** `--print/-p [prompt]` → non-interactive single `agent.turn` → final assistant text to stdout, trace to stderr → exit 0 (ok) / 1 (error or empty). No confirmation prompts in print mode.

**Tool call:**
LLM returns tool_call → agent checks policy (workspace boundary, confirm rules) → `tools.*` executes → result as tool_result → next LLM request.

**Session:**
JSONL at `~/.tether/sessions/<id>.jsonl`. One event per line. `-r` picks latest by mtime matching `meta.workspace`.

## Key decisions

- **Single binary (M6, done):** Lua modules embedded as C arrays via `tools/embed.lua` generator. No external Lua install needed; binary is standalone.
- **OpenAI-compatible first:** Anthropic/Google adapters share the same `stream()`/`list_models()` contract.
- **Retries:** `cfg.retries` attempts (default 3), exponential backoff (0.5/1/2s), only on 429/5xx/empty/network. Respects `Retry-After`. No retry on 4xx. Emits `retry` event.
- **Confirmation policy:** `write`, `patch`, `run` outside workspace require user confirmation. `[A] always` persists to `~/.tether/config.lua` `auto_approve`.
- **Token budget:** `context.max_tokens` (default 32768); summarize at 70% via `context.summarize_at`.
- **UI regions:** transcript (flex) / error banner / input / palette / hint / status line. No header.
- **Input modes:** bracketed paste (`ESC[200~…ESC[201~`); mouse SGR (`[?1006h`, wheel → transcript scroll, click → palette/confirmation select); keyboard protocol detection (`TERM_PROGRAM`/`TERM` → kitty `ESC[?u` + `Ctrl+Shift+C` copy, modifyOtherKeys/VTE/X11 → `Ctrl+J` newline fallback); `Ctrl+C` double-tap quit. OSC 52 clipboard with pbcopy/xclip/wl-copy fallback.
- **ASCII mode:** `NO_COLOR=1` or `TERM=dumb` strips ANSI codes, replaces Unicode glyphs with ASCII equivalents.
- **System prompt:** configurable via `config.system_prompt` (string or file path).
- **Debug log:** `--debug` writes to `~/.tether/log/tether.log`; `/log` overlay shows last 200 lines.
- **UI collapse:** `ui.collapse.read/list/grep` thresholds cap tool block display height.
- **SSE tool_call assembly (M7):** argument deltas are emitted RAW (still
  JSON-escaped) and addressed by `id` or `index` (continuation chunks carry no
  id); exactly one unescape happens in `agent.parse_args` over the fully
  assembled string — chunk boundaries may split escape sequences.
- **Confirmation idempotency (M7):** `drive_pending` emits each call's
  confirmation at most once (`call.confirm_emitted`); repeated `agent.continue`
  never re-shows a menu. `[d] details` keeps the menu alive under the overlay.
- **Resume (M7):** `-r` and `/resume` restore `role=="tool"` messages via
  `agent.add_tool_result` — otherwise the API rejects the first turn (400).
- **Print exit codes (M7):** `--print` exits 1 on error OR empty response;
  non-SSE error bodies surface as error events (`http <status>: <body>`).

## Deferred (post-MVP)

Anthropic/Google adapters, PTY, background tasks, git integration, LSP, multi-session, themes, vector memory, drag selection.
