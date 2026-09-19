# tether — tech-spec

## Architecture

Two layers, one binary:

```
C host (src/host)          Lua core (src/tether)
─────────────────          ────────────────────
termios / raw mode         app, ui, agent, api
shell exec (tether.exec)   tools, session, config
fs primitives, krep search markdown-lite, overlays
HTTP(S) in-process         (vendored libcurl + mbedTLS)
Lua embed (static arrays)
```

C host exposes a narrow syscall API to Lua. All agent logic is Lua.

## Data flow

**Chat stream:**
`agent` builds request → `api.stream` → C host performs the request in-process (vendored libcurl + mbedTLS, no subprocess) → SSE parsed → canonical events (`text_delta`, `reasoning_delta`, `tool_call_*`, `usage`, `done`, `error`, `retry`, `context_compressed`) → `ui` renders transcript.

**Print mode:** `--print/-p [prompt]` → non-interactive single `agent.turn` → final assistant text to stdout, trace to stderr → exit 0 (ok) / 1 (error or empty). No confirmation prompts in print mode.

**Tool call:**
LLM returns tool_call → agent checks policy (workspace boundary, confirm rules) → `tools.*` executes → result as tool_result → next LLM request.

**Session:**
JSONL at `~/.tether/sessions/<id>.jsonl`. One event per line. `-r` picks latest by mtime matching `meta.workspace`.

## Key decisions

- **Single binary (M6, done):** Lua modules embedded as C arrays via `tools/embed.lua` generator. No external Lua install needed; binary is standalone. The build also vendors krep (grep), libcurl + mbedTLS + zlib (HTTPS) and links them statically, so `ldd ./tether` shows only `libc` and `libm` — no `curl`, `rg`, `grep`, `ls`, `find`, `chmod` or `mkdir` binary is required at runtime. (`tools.run` still uses `/bin/sh -c`; that is a deliberate feature, not an accidental dependency.)
- **Providers (M10, done):** `api.lua` is a dispatcher over `src/tether/providers/{openai,anthropic,gemini}.lua` sharing one in-process transport (`tether.http_stream`/`tether.http_get` over vendored libcurl + mbedTLS, header/body temp files, retry/backoff, error surfacing). Every adapter emits the same canonical events, so `agent.lua` has no provider branches. `cfg.provider` selects the adapter (`openai` default, unknown warns + falls back); per-provider `api_key_env`/`base_url`/`model` resolve via the `providers` table with legacy top-level keys as `openai` defaults.
- **Retries:** `cfg.retries` attempts (default 3), exponential backoff (0.5/1/2s), only on 429/5xx/empty/network. Respects `Retry-After`. No retry on 4xx. Emits `retry` event.
- **SSE streaming:** C `http_stream` reads the body with a libcurl write callback and invokes the Lua `on_line` callback once per line; empty SSE lines surface as `""` (event boundary). The callback is invoked until transfer end, and a trailing line without a newline is still delivered.
- **Filesystem primitives:** `tether.mkdirp`, `tether.fchmod`, `tether.readdir`, `tether.stat` are the only mechanism the application uses to create directories, change permissions, list directories or read metadata — no `mkdir -p`/`ls`/`find`/`chmod` shell-outs remain.
- **grep backend:** `tools.grep` runs the vendored krep engine in-process (POSIX ERE, honors `.gitignore` by default, supports `glob`/`ignore_case`/`max_results`). Records are `{path, line, column, text}` with `column` always 1, because krep's printed form carries no column.
- **Confirmation policy:** `write`, `patch`, `run` outside workspace require user confirmation (the patch target is read from the diff headers). `[A] always` persists anchored patterns to `~/.tether/auto_approve.lua`, which `config.load` reads back on the next start.
- **Token budget:** `context.max_tokens` (default 32768); summarize at 70% via `context.summarize_at`.
- **Compression boundary:** retained tool results include their preceding assistant tool-call message.
- **UI regions:** transcript (flex) / error banner / input / palette / status line. No header, no hint row (M9). Alt-screen on by default (T48) — `cfg.ui.alt_screen=false` opts out; status line shows context usage as `4.1k/32k (13%)` (T47).
- **Input modes:** bracketed paste (`ESC[200~…ESC[201~`); mouse SGR (`[?1006h` + `[?1000h`, wheel → transcript scroll, click → palette/confirmation select, `ui.mouse` = `auto`/`on`/`off`/`selection`); the keyboard protocol is detected from `TERM_PROGRAM`/`TERM`, enabled for the session and restored on exit (kitty: push `CSI > 1 u` / pop `CSI < u`; xterm-alikes: `CSI > 4 ; 2 m` / `CSI > 4 ; 0 m`), and both CSI-u and modifyOtherKeys keys are decoded into the legacy key table (`Shift+Enter` newline, `Ctrl+Shift+C` copy, `Ctrl+Up/Down` history); `Ctrl+C` double-tap quit. Clipboard is OSC 52 only.
- **ASCII mode:** `NO_COLOR=1` or `TERM=dumb` strips ANSI codes, replaces Unicode glyphs with ASCII equivalents.
- **System prompt:** configurable via `config.system_prompt` (string or file path).
- **Debug log:** `--debug` writes to `~/.tether/log/tether.log` (file only; no TUI overlay — M9).
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

PTY, background tasks, git integration, LSP, multi-session, themes, vector memory, drag selection.
