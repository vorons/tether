# tether

Terminal-based AI coding agent — Go-free, Lua + C single binary.

## Build

```sh
make          # build tether binary
make test     # luac + lua tests + host smoke
make clean    # wipe build artifacts
```

## Usage

```sh
./tether                  # interactive TUI
./tether --workspace ~/myproj
./tether --model claude-opus
./tether --print "prompt"  # non-interactive one-shot; or pipe stdin
./tether --resume         # resume latest session for this workspace
./tether -r -w ~/proj -m o3
./tether --agents-file ~/my-rules.md  # extra instruction file(s), repeatable
./tether --version        # print version and exit
./tether --debug          # verbose logging to ~/.tether/log/tether.log
```

## AGENTS.md and skills

The system prompt is composed at session start from several sources, in this
order:

1. The base — `system_prompt` from `~/.tether/config.lua` when set, otherwise
   the built-in tool description.
2. `AGENTS.md` auto-discovered at `$HOME/AGENTS.md`, then
   `<workspace>/AGENTS.md` (missing files ignored; unreadable files warn on
   stderr). Each AGENTS.md file is capped at 16 KB.
3. Explicit agents files: `agents_files` from the config, then the repeatable
   `--agents-file <path>` CLI flag (config entries first, flag entries in the
   order given). Unreadable paths warn and are skipped.
4. The skills index (below).

```sh
./tether --agents-file ~/my-rules.md --agents-file ./extra.md
```

### Skills

A skill is a directory containing a `SKILL.md` with YAML frontmatter
(`name`, `description`). Discovered from, in order (first-wins on name
collision):

- `~/.tether/skills/<name>/SKILL.md`
- `<workspace>/.tether/skills/<name>/SKILL.md`
- `~/.agents/skills/<name>/SKILL.md`
- `<workspace>/.agents/skills/<name>/SKILL.md`

Set `skills_dirs` in the config (list of directory paths) to replace the
default set.

Only the skill *index* (name, description, file path) is injected into the
prompt — the full `SKILL.md` body is not auto-loaded. The agent reads the file
with the `read` tool when a task matches the skill's description. A `SKILL.md`
without frontmatter, or missing `description`, is listed with an empty
description and the directory name as its name.

```markdown
---
name: deploy
description: Ship the app to staging
---
# Deploy
Run `make release` then ...
```

The model list depends on your OpenAI-compatible provider; `/model` falls
back to a static list — set `model = "..."` in `~/.tether/config.lua` for
direct control.

## The `ask` tool

The model can stop and ask instead of guessing. `ask(questions)` renders a
question block in the transcript — options, an always-available freeform answer,
per-option notes — and the user's answer comes back to the model as a tool result
carrying a JSON payload:

```json
{"answers":[{"id":"framework","question":"Which framework?","selected":["React"],"other":"typed by hand","notes":[{"option":"Vue","note":"too heavy"}]}]}
```

The argument is an array of questions:

```json
{
  "questions": [{
    "id": "framework",
    "question": "Which framework should we use?",
    "description": "Optional markdown context rendered above the options",
    "recommended": 2,
    "options": [{ "label": "React" }, { "label": "Vue" },
                { "label": "Svelte", "description": "smallest bundle" }]
  }, {
    "id": "constraints",
    "question": "Which constraints apply?",
    "multi": true,
    "options": [{ "label": "No breaking changes" }, { "label": "Zero dependencies" }]
  }]
}
```

- Up to 8 questions and 12 options each; one call is one answer set, shown one
  question at a time with an `N/M` indicator.
- Keys: `↑`/`↓` move across the options and the freeform row, `Enter` submits a
  single-answer question (or accepts a `multi` selection and moves on), a digit
  `1..9` picks that option, `Space` toggles an option of a `multi` question, `Tab`
  edits the highlighted option's note (or the freeform answer), `←` returns to
  the previous question with its answer intact, `Esc` cancels the whole set.
- The last row is always `Other (ввести свой вариант)`: Enter opens it, Enter
  commits the text, and once text is committed Enter submits the question. It is
  also how a question with no usable options is answered.
- A note belongs to the option it was written on and is returned even when that
  option was not selected; `recommended` only flags the model's suggestion and
  never preselects it.
- `Esc` cancels without stopping the turn — the model can proceed or ask
  differently — and a cancel raises no error banner.
- Under `--print` there is nobody to ask: the call returns an error result saying
  so, the model decides on its own, and the run still prints its answer.

## Providers

`tether` speaks three APIs through one canonical event stream
(`src/tether/providers/`): `openai` (default, any OpenAI-compatible
`/chat/completions` endpoint), `anthropic` (Claude Messages API) and
`gemini` (Google `streamGenerateContent` with `generateContent`
fallback). The agent loop, tools and confirmations are identical on
all providers.

```lua
-- ~/.tether/config.lua
return {
  provider = "anthropic", -- "openai" | "anthropic" | "gemini"
  providers = {
    openai    = { api_key_env = "OPENAI_API_KEY" }, -- default base_url kept
    anthropic = { api_key_env = "ANTHROPIC_API_KEY",
                  model = "claude-sonnet-4-20250514" },
    gemini    = { api_key_env = "GEMINI_API_KEY",
                  model = "gemini-2.5-flash" },
  },
  -- optional: replace the default skill-dir discovery set
  -- skills_dirs = { "~/my-skills", "./project-skills" },
  -- optional: persistent agents instruction files (merged before --agents-file)
  -- agents_files = { "~/shared/rules.md" },
}
```

Resolution per provider: `providers.<name>.{api_key_env,base_url,model}`
wins, otherwise the legacy top-level `api_key_env`/`base_url`/`model`
(which stay the `openai` defaults, so custom OpenAI-compatible proxies
keep working untouched). `--model/-m` and `/model` operate on the
active provider; an unknown `provider` warns on stderr and behaves as
`openai`. Keys never appear in argv: OpenAI/Anthropic go through a
`chmod 600` header file (`x-api-key` for Anthropic), Gemini uses the
`?key=` query convention without logging the command line.

```sh
```

## Slash commands

`/clear /compact /model /resume /new /quit /copy`

Typing `/` opens one palette listing those commands followed by every
discovered skill as `/skill-name`. Filtering is a case-insensitive
subsequence match over the whole list; when the list is longer than the
window the palette scrolls (at most 8 rows and at most half the terminal
height) so the selected row stays visible, with a dim `N/total` indicator on
the row below the entries. Skill rows show a `[задача]` hint for the task text
that follows the name. Enter runs the highlighted command, or completes
`/<name> ` into the input for a skill — submitting that then sends the name to
the agent as an ordinary message, and the agent reads the skill file through
the skills index in its prompt.

- `/clear` clears the transcript display only — the agent keeps its
  history, so the next turn still sees the full context. `/new`
  starts a truly fresh session (history and transcript are dropped).
- `/resume` opens a picker of the last 10 sessions for the workspace.
- Confirmation menu for `write`/`patch`/`run` outside workspace: `[y] once`,
  `[a] session`, `[A] always` (persists to `~/.tether/auto_approve.lua`),
  `[d] details`, `[n] deny`, `Esc` cancels the turn. Digits `1..6` work too.

## TUI features

- **Markdown-lite rendering** of assistant replies: code blocks in a frame,
  inline code, bold/italic, lists, headings.
- **Syntax highlighting** in fenced code blocks: lua, c, sh, python, js, go,
  rust, json (`ui.highlight`, on by default for truecolor/256-color terminals,
  off for mono/ascii).
- **Tool result rows**: a leading `✓`/`✗`/pending marker with a one-line
  summary; a failed call shows its first error line clipped to the row, with
  the full error behind expansion. Expanded `read`/`grep` bodies are
  syntax-highlighted from the file extension.
- **Expansion**: `Ctrl+O` toggles the newest tool result visible in the
  viewport, `Ctrl+Shift+O` toggles all results at once (on terminals that
  report the Shift modifier); with `ui.mouse = "on"` a left click toggles the
  clicked result. On plain terminals `Ctrl+O` keeps its expand-all meaning.
- **Diffs for `write`/`patch`**: the result body renders as a unified diff
  with old/new line numbers, add/remove colours and word-level emphasis; the
  row summary reports `+N −M` with a proportional meter and whether the file
  was created or overwritten. While the call is pending, the projected diff
  is previewed before the tool runs.
- **Turn separators** — a dim `── HH:MM ──` row before each user turn
  (`ui.turn_separators`;
  set `false` to hide).
- **`@path` tab completion** in the input line: Tab completes the
  workspace-relative path token under the cursor to workspace entries (an
  `@` prefix is preserved); `ui.path_completion` sets `false` to disable.
- **Live turn feedback**: replies repaint as they stream (with a `▌` caret on
  the newest line), and a `✻ tether думает…` placeholder plus a spinner and
  elapsed time in the input box's top rule cover the wait before the first
  token.
- **Token usage** in the footer stats row as `4.1k/32k (13%)` — used over
  budget, colored by threshold (green → yellow at summarize threshold → red
  at 90%+).
- **Mouse modes** (`ui.mouse` in `~/.tether/config.lua`):
  `"auto"` (default — mouse only over menus, native text selection works),
  `"on"` (always), `"off"` (never), `"selection"` (off + manual copy).
  With mouse on, hold `Shift` while dragging to use terminal-native selection.
- **Alt-screen** by default (`ui.alt_screen = true`): the TUI repaints in the
  alternate screen buffer, so shell scrollback stays intact behind it;
  `false` opts back into in-place rendering.
- **ASCII fallback**: on `TERM=dumb`/`NO_COLOR` all glyphs degrade to ASCII.
- **`/copy`** — copies the last assistant answer, last tool output, last
  code block, or the full transcript to the clipboard.
- **Slash palette with skills** — `/` lists the commands and every discovered
  skill as `/name` (with the skill's argument hint); the list scrolls in a
  window with an `N/total` indicator, and picking a skill only writes
  `/<name> ` into the input. Submitting `/<name>` sends it to the agent as a
  normal message; `/skills` no longer exists.
- **`↓ +N` marker** on the newest visible transcript row while the user is
  scrolled up; the footer flag row shows the same `↓ +N` count.
- **Retry and continuation notices** — a failed attempt that is about to be
  retried drops the rows it already painted and leaves one dim
  `↻ повтор N (ждём Xs): reason` row, with the pending retry also shown in the
  input box's top rule; a truncated answer that is continued leaves a dim
  `↻ продолжение (лимит вывода)` row, and an answer that stayed empty after its
  nudge ends the turn with an error instead of silence. Ctrl+C still aborts,
  including while the agent waits between attempts.

## Config keys

UI keys live under `ui = { ... }` in `~/.tether/config.lua`:

- `ui.highlight = "auto"` — syntax highlighting in fenced code blocks and in
  expanded `read`/`grep` tool bodies. Values: `"auto"` / `"on"` / `"off"`.
  `auto` turns highlighting on when the terminal color depth is above 16
  colors, off for mono/ascii.
- `ui.turn_separators = true` — dim `── HH:MM ──` dividers before consecutive
  user turns; set `false` to disable.
- `ui.path_completion = true` — Tab completes the workspace-relative path
  token in the input line; set `false` to disable.
- `ui.ascii = "auto"` — ASCII glyphs and no color. `"auto"` follows
  `NO_COLOR=1`/`TERM=dumb`; `"on"`/`true` forces it, `"off"`/`false` disables it.
- `ui.theme = "default"` — `default`, `solarized` or `mono`; every UI role,
  including syntax highlighting, follows the theme (`mono` emits no color).

Retry behavior is a top-level `retry = { ... }` table, not a UI key:

- `retry.base_delay_ms = 2000` — wait before the first retry.
- `retry.max_delay_ms = 60000` — the cap the exponential wait grows to.
- `retry.multiplier = 2` — how fast the wait grows; a value below 1 counts
  as 1, and an invalid value falls back to the default.
- `retry.max_failures_at_max_delay = 3` — failures at the capped wait allowed
  before the turn gives up. The loop also stops immediately on a permanent
  failure (invalid API key, model not found) or an exhausted quota / session
  limit / budget; a connection error, a 429/5xx, a 400/413, stream exhaustion
  or a credit error is retried.
- `retry.max_attempts` — optional hard cap on the attempts in one turn. The
  legacy top-level `retries = N` still does the same thing; there is no
  default attempt cap.

With the defaults the waits are 2s → 4s → 8s → 16s → 32s → 60s → 60s → 60s,
so a turn makes at most nine attempts. A `Retry-After` from the server
replaces the wait for the next attempt.

## Architecture

- **C host** (`src/host/main.c`): embeds Lua 5.4.6, exports narrow syscall API — `tether.exec` (the only shell primitive, used by the `run` tool), `tether.getcwd`, `tether.realpath`, `tether.get_terminal_size`, `tether.is_tty`, `tether.write`, `tether.read_char`, `tether.sleep`, the filesystem primitives `tether.mkdirp`/`tether.fchmod`/`tether.readdir`/`tether.stat`, the krep grep backend `tether.krep_search`, and the in-process HTTP client `tether.http_stream`/`tether.http_get`. The binary is self-contained: `ldd ./tether` shows only `libc` and `libm`
- **Lua modules** (`src/tether/`): loaded as globals via `lua_setglobal`
  - `config` — configuration loading, validation
  - `tools` — file I/O: `read`, `list`, `glob`, `grep`, `write`, `patch`, `run`
  - `ask` — the `ask` tool's pure rules: question normalisation and bounds, the
    answer payload, the transcript summary
  - `diff` — pure-Lua unified-diff engine (hunks, parsing, word pairing, meter)
  - `api` — SSE streaming to LLM via the in-process HTTPS transport
  - `agent` — tool dispatch loop, conversation history
  - `session` — JSONL journal, auto-save, resume by workspace
  - `ui` — TUI rendering, input handling, confirmation/diff overlays
  - `app` — CLI argument parsing, session lifecycle, error handling

## Key Design Decisions

- **In-process HTTPS**: `api.lua` uses `tether.http_stream` (per-line callback) and `tether.http_get`, backed by vendored libcurl + mbedTLS + zlib — no `curl` subprocess, no external CLI tools (grep runs the vendored krep engine)
- **Lua-only logic**: All agent logic lives in Lua; C host has zero AI knowledge
- **No `load`**: all JSON parsing is hand-rolled recursive descent or gmatch patterns (see `docs/decisions/2026-09-17-lua-json-parser.md`)
- **Secrets**: the API key is passed to the HTTP client via a private header file (`tether.fchmod` 600), never in argv or in the environment
- **Shell injection**: `tools.run` uses `env TETHER_WORKSPACE=<dir> sh -c` with `timeout`

## Testing

- `luac -p` validates all Lua modules on every `make test`
- `tests/lua_tests.lua` — unit tests for json_encode, parse_json_str, path resolution, glob matching
- `tests/host_smoke.sh` — end-to-end pipe/EOF tests
