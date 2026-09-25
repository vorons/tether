# tether — tech-spec

## Architecture

Two layers, one binary:

```
C host (src/host)          Lua core (src/tether)
─────────────────          ────────────────────
termios / raw mode         app, ui, agent, api
shell exec (tether.exec)   tools, session, config
fs primitives, krep search markdown-lite, palette modes
HTTP(S) in-process         (vendored libcurl + mbedTLS)
Lua embed (static arrays)
```

C host exposes a narrow syscall API to Lua. All agent logic is Lua.

## Data flow

**Chat stream:**
`agent` builds request → `api.stream` → C host performs the request in-process (vendored libcurl + mbedTLS, no subprocess) → SSE parsed → canonical events (`text_delta`, `reasoning_delta`, `tool_call_*`, `usage`, `done` with a stop reason, `context_compressed`) → `ui` renders transcript. A failed attempt is not an event: `api.stream` returns a classified failure and the agent's turn loop decides whether to retry it (`retry`), continue a truncated answer (`continuation`) or surface it (`error`).

**Print mode:** `--print/-p [prompt]` → non-interactive single `agent.turn` → final assistant text to stdout, trace to stderr → exit 0 (ok) / 1 (error or empty). No confirmation prompts in print mode.

**Tool call:**
LLM returns tool_call → agent checks policy (workspace boundary, confirm rules) → `tools.*` executes → result as tool_result → next LLM request.

**Ask:**
LLM returns an `ask` tool_call → the pending queue never executes it: the agent emits one `ask` event on the canonical event stream and parks the turn exactly as it does for a confirmation → `ui` renders the question block → the user answers (or cancels) → `agent.answer_ask` records the JSON answer payload as that call's tool result and `agent.continue` resumes the loop. In a run with no interactive user (`--print`) the call degrades to an error tool result and the loop continues.

**Session:**
JSONL at `~/.tether/sessions/<id>.jsonl`. One event per line. `-r` picks latest by mtime matching `meta.workspace`.

## Key decisions

- **Single binary (M6, done):** Lua modules embedded as C arrays via `tools/embed.lua` generator. No external Lua install needed; binary is standalone. The build also vendors krep (grep), libcurl + mbedTLS + zlib (HTTPS) and links them statically, so `ldd ./tether` shows only `libc` and `libm` — no `curl`, `rg`, `grep`, `ls`, `find`, `chmod` or `mkdir` binary is required at runtime. (`tools.run` still uses `/bin/sh -c`; that is a deliberate feature, not an accidental dependency.)
- **Providers (M10, done):** `api.lua` is a dispatcher over `src/tether/providers/{openai,anthropic,gemini}.lua` sharing one in-process transport (`tether.http_stream`/`tether.http_get` over vendored libcurl + mbedTLS, header/body temp files, per-attempt failure classification). Every adapter emits the same canonical events, so `agent.lua` has no provider branches. `cfg.provider` selects the adapter (`openai` default, unknown warns + falls back); per-provider `api_key_env`/`base_url`/`model` resolve via the `providers` table with legacy top-level keys as `openai` defaults.
- **Retries:** one owner — the agent's turn loop — so a single backoff schedule governs every failure; `api.stream` makes exactly one attempt and returns `ok, failure` with the policy's classification. `src/tether/retry.lua` holds the pure policy: classification (catch-all retryable, with a permanent blacklist for invalid keys/models and a quota/session-limit/budget stop), the exponential schedule (`retry.base_delay_ms` 2000 / `retry.max_delay_ms` 60000 / `retry.multiplier` 2 / `retry.max_failures_at_max_delay` 3, legacy `retries` as an attempt cap), the `Retry-After` override, and the continuation policy (truncated answers continue with a hidden user turn; an empty stop gets one nudge). Failed attempts are retried with the same conversation, never journaled, and their streamed rows are dropped by the UI.
- **SSE streaming:** C `http_stream` reads the body with a libcurl write callback and invokes the Lua `on_line` callback once per line; empty SSE lines surface as `""` (event boundary). The callback is invoked until transfer end, and a trailing line without a newline is still delivered.
- **Filesystem primitives:** `tether.mkdirp`, `tether.fchmod`, `tether.readdir`, `tether.stat` are the only mechanism the application uses to create directories, change permissions, list directories or read metadata — no `mkdir -p`/`ls`/`find`/`chmod` shell-outs remain.
- **grep backend:** `tools.grep` runs the vendored krep engine in-process (POSIX ERE, honors `.gitignore` by default, supports `glob`/`ignore_case`/`max_results`). Records are `{path, line, column, text}` with `column` always 1, because krep's printed form carries no column.
- **Structured questions (`ask`, done):** the tool rides the existing parked-turn path rather than a second waiting mechanism — `drive_pending` emits one `ask` event (idempotent, like a confirmation), parks, and `agent.answer_ask` records the payload before the UI resumes with `agent.continue`. The rules (bounds, ids, option labels, degradation of a malformed set, the answer payload with `selected`/`other`/`notes`, the summary) are pure data in → data out in `src/tether/ask.lua`. The block is a synthetic transcript tail entry (`S.ask_entry`) with modal key ownership (`list`/`other`/`note`), answers revisited with `←`, `Enter` submitting once a freeform answer is committed, `Esc` cancelling the whole batch (every `ask` still pending in the step) while the turn continues without an error, and `cfg.non_interactive` (set by `--print`) turning the call into an error tool result instead of parking.
- **Confirmation policy:** `write`, `patch`, `run` outside workspace require user confirmation (the patch target is read from the diff headers). `[A] always` persists anchored patterns to `~/.tether/auto_approve.lua`, which `config.load` reads back on the next start.
- **Token budget:** `context.max_tokens` (default 32768); summarize at 70% via `context.summarize_at`.
- **Compression boundary:** retained tool results include their preceding assistant tool-call message.
- **UI regions:** transcript (flex) / error banner / input box (top rule, content rows with `ui.editor_padding_x`, bottom rule) / palette / footer (single row: path, token/context stats, transient flags, model right-aligned). The palette paints a window of at most `min(8, floor(h/2))` rows that shifts to keep the selection visible, plus a `N/total` indicator row inside the region it already reserves when the entry list overflows it. No header, no hint row (M9). Alt-screen on by default (T48) — `cfg.ui.alt_screen=false` opts out; footer shows context usage as `4.1k/32k (13%)` (T47). The caret is a reverse-video block (not a hardware cursor); the top rule carries turn status and `↑ N more` labels, the bottom rule carries `↓ N more`.
- **Input modes:** bracketed paste (`ESC[200~…ESC[201~`); mouse SGR (`[?1006h` + `[?1000h`, wheel → transcript scroll, click → palette/confirmation select and, with `ui.mouse = "on"`, tool-row expand toggle, `ui.mouse` = `auto`/`on`/`off`/`selection`); the keyboard protocol is detected from `TERM_PROGRAM`/`TERM`, enabled for the session and restored on exit (kitty: push `CSI > 1 u` / pop `CSI < u`; xterm-alikes: `CSI > 4 ; 2 m` / `CSI > 4 ; 0 m`), and both CSI-u and modifyOtherKeys keys are decoded into the legacy key table (`Shift+Enter` newline, `Ctrl+Shift+C` copy, `Up/Down` (and `Ctrl+Up/Down`) input history); `Ctrl+C` aborts the running turn — while a turn blocks the UI is not reading stdin, so the host watches it itself, wakes `tether.sleep` and aborts an in-flight HTTP transfer, reporting the interrupt through `tether.abort_requested()`/`clear_abort()` — and double-tap quits. Clipboard is OSC 52 only.
- **ASCII mode:** `NO_COLOR=1` or `TERM=dumb` strips ANSI codes, replaces Unicode glyphs with ASCII equivalents.
- **Module resolution:** the C host loads each Lua module and exposes it as a global (`load_module` → `lua_setglobal`, no `package.preload`), so application code reaches modules as globals (`agent`, `session`, `config`, `api`, `context`, `tools`) and `require` is only a fallback for the plain-Lua test harness. A `require`-only lookup silently disables the feature it guards in the binary — that is how Tab path completion and the `/skills` palette were both dead in shipped builds while their stubbed tests passed. `path_complete_tab` reads the `tools` global, and `tools.path_complete` returns candidates qualified with the typed directory (`sub/inner.lua` for token `sub/in`) because the UI replaces the whole token with the chosen candidate.
- **System prompt:** configurable via `config.system_prompt` (string or file path).
- **Debug log:** `--debug` writes to `~/.tether/log/tether.log` (file only; no TUI view — M9).
- **UI collapse & tool rows:** `ui.collapse.read/list/grep` thresholds cap tool block display height. Tool rows lead with a `✓`/`✗`/pending marker and a one-line summary; a failed call carries its first error line clipped to the row, the full error behind expansion. `Ctrl+O` toggles the newest visible tool entry, `Ctrl+Shift+O` toggles all (plain terminals keep `Ctrl+O` = all), and a left click toggles an entry when `ui.mouse = "on"`.
- **Diff rendering:** `src/tether/diff.lua` is a pure-Lua unified-diff engine (`unified`/`parse`/`pair_words`/`meter`). `write`/`patch` bodies become the applied diff (computed from the projection's before-content, no second read) and render with old/new line numbers, add/remove roles, path-keyed syntax highlighting and word-level emphasis. The row summary reports `+N −M` with a proportional meter; a pending `write`/`patch` previews the agent-supplied read-only projection (inside workspace, ≤ 1 MiB, no write/history), replaced by the result or dropped on deny/cancel/abort.
- **Tool output sanitization:** transcript rendering strips every control sequence except SGR (cursor moves, erase, `\r`, OSC/DCS) and collapses blank-line runs; display-only, so the model/journal/`/copy` bodies stay raw. SGR survives only while colour is on.
- **Slash palette & skills:** one palette holds the built-in commands followed by every discovered skill as `/name` (discovery is resolved once per palette open, a failure degrades to commands only, and skill rows carry the `[skill]` hint). Picking a skill only composes `/<name> ` into the input; submitting `/<name>` for a discovered skill sends it to the agent as an ordinary message, and name lookup ignores case for commands and skills alike, so a command always owns a colliding token (such a skill is neither listed nor dispatched). `/skills` and its `[skill: …]` reference are gone. `context` is reached as a global, the way the host registers modules (`load_module` in `main.c`), not through `require`.
- **SSE tool_call assembly (M7):** argument deltas are emitted RAW (still
  JSON-escaped) and addressed by `id` or `index` (continuation chunks carry no
  id); exactly one unescape happens in `agent.parse_args` over the fully
  assembled string — chunk boundaries may split escape sequences.
- **Confirmation idempotency (M7):** `drive_pending` emits each call's
  confirmation at most once (`call.confirm_emitted`); repeated `agent.continue`
  never re-shows a menu. The menu offers allow/session/always/deny/cancel
  (digits 1..5); projected diffs stay on pending tool-rows.
- **Resume (M7):** `-r` and `/resume` restore `role=="tool"` messages via
  `agent.add_tool_result` — otherwise the API rejects the first turn (400).
- **Print exit codes (M7):** `--print` exits 1 on error OR empty response;
  non-SSE error bodies surface as error events (`http <status>: <body>`).

## Deferred (post-MVP)

PTY, background tasks, git integration, LSP, multi-session, themes, vector memory, drag selection.
