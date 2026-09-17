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
./tether --version        # print version and exit
./tether --debug          # verbose logging to ~/.tether/log/tether.log
```

The model list depends on your OpenAI-compatible provider; `/model` falls
back to a static list — set `model = "..."` in `~/.tether/config.lua` for
direct control.

```sh
```

## Slash commands

`/help /clear /compact /model /resume /new /status /log /quit`

- `/resume` opens a picker of the last 10 sessions for the workspace.
- Confirmation menu for `write`/`patch`/`run` outside workspace: `[y] once`,
  `[a] session`, `[A] always` (persists to `~/.tether/auto_approve.lua`),
  `[d] details`, `[n] deny`, `Esc` cancels the turn. Digits `1..6` work too.

## TUI features

- **Markdown-lite rendering** of assistant replies: code blocks in a frame,
  inline code, bold/italic, lists, headings.
- **Search**: `Ctrl+F`, then `Enter`/`n`/`N`/`F3`/`Shift+F3` to jump between
  matches, `Esc` to cancel; the active match line is highlighted.
- **Token bar** in the status line (green → yellow at summarize threshold →
  red at 90%+).
- **Mouse modes** (`ui.mouse` in `~/.tether/config.lua`):
  `"auto"` (default — mouse only over menus, native text selection works),
  `"on"` (always), `"off"` (never), `"selection"` (off + manual copy).
  With mouse on, hold `Shift` while dragging to use terminal-native selection.
- **Alt-screen** opt-in: `ui.alt_screen = true` repaints in the alternate
  screen buffer; default `false` keeps native terminal scrollback.
- **ASCII fallback**: on `TERM=dumb`/`NO_COLOR` all glyphs degrade to ASCII.

## Architecture

- **C host** (`src/host/main.c`): embeds Lua 5.4.6, exports narrow syscall API (`tether.exec`, `tether.open_pipe`, `tether.read_line`, `tether.close_pipe`, `tether.pipe_eof`, `tether.getcwd`, `tether.write`, `tether.read_char`)
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
