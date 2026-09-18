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

`/clear /compact /model /resume /new /quit /copy /skills`

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
- **Turn separators** — a dim `── HH:MM ──` row before each user turn
  (`ui.turn_separators`;
  set `false` to hide).
- **`@path` tab completion** in the input line: Tab completes the
  workspace-relative path token under the cursor to workspace entries (an
  `@` prefix is preserved); `ui.path_completion` sets `false` to disable.
- **Live turn feedback**: replies repaint as they stream (with a `▌` caret on
  the newest line), and a `✻ tether думает…` placeholder plus a spinner and
  elapsed time in the status line cover the wait before the first token.
- **Token usage** in the status line as `4.1k/32k (13%)` — used over budget,
  colored by threshold (green → yellow at summarize threshold → red at 90%+).
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
- **`/skills`** — lists available skills and appends the chosen skill's
  reference to the input line.
- **`↓ +N` marker** on the newest visible transcript row while the user is
  scrolled up; the status line shows the same `↓ +N` count.

## Config keys

UI keys live under `ui = { ... }` in `~/.tether/config.lua`:

- `ui.highlight = "auto"` — syntax highlighting in fenced code blocks.
  Values: `"auto"` / `"on"` / `"off"`. `auto` turns highlighting on when
  the terminal color depth is above 16 colors, off for mono/ascii.
- `ui.turn_separators = true` — dim `── HH:MM ──` dividers before consecutive
  user turns; set `false` to disable.
- `ui.path_completion = true` — Tab completes the workspace-relative path
  token in the input line; set `false` to disable.
- `ui.ascii = "auto"` — ASCII glyphs and no color. `"auto"` follows
  `NO_COLOR=1`/`TERM=dumb`; `"on"`/`true` forces it, `"off"`/`false` disables it.
- `ui.theme = "default"` — `default`, `solarized` or `mono`; every UI role,
  including syntax highlighting, follows the theme (`mono` emits no color).

## Architecture

- **C host** (`src/host/main.c`): embeds Lua 5.4.6, exports narrow syscall API (`tether.exec`, `tether.open_pipe`, `tether.read_line`, `tether.close_pipe`, `tether.pipe_eof`, `tether.getcwd`, `tether.realpath`, `tether.get_terminal_size`, `tether.is_tty`, `tether.write`, `tether.read_char`, `tether.sleep`)
- **Lua modules** (`src/tether/`): loaded as globals via `lua_setglobal`
  - `config` — configuration loading, validation
  - `tools` — file I/O: `read`, `list`, `glob`, `grep`, `write`, `patch`, `run`
  - `api` — SSE streaming to LLM via C host pipes
  - `agent` — tool dispatch loop, conversation history
  - `session` — JSONL journal, auto-save, resume by workspace
  - `ui` — TUI rendering, input handling, confirmation/diff overlays
  - `app` — CLI argument parsing, session lifecycle, error handling

## Key Design Decisions

- **SSE via pipes**: `api.lua` uses `tether.open_pipe` → `tether.read_line` for non-blocking streaming
- **Lua-only logic**: All agent logic lives in Lua; C host has zero AI knowledge
- **No `load`**: all JSON parsing is hand-rolled recursive descent or gmatch patterns (see `docs/decisions/2026-09-17-lua-json-parser.md`)
- **Secrets**: the API key is passed to curl via a private header file (`chmod 600`), never in argv
- **Shell injection**: `tools.run` uses `env TETHER_WORKSPACE=<dir> sh -c` with `timeout`

## Testing

- `luac -p` validates all Lua modules on every `make test`
- `tests/lua_tests.lua` — unit tests for json_encode, parse_json_str, path resolution, glob matching
- `tests/host_smoke.sh` — end-to-end pipe/EOF tests
