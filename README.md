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
./tether --print          # non-interactive (prints tool output)
./tether --resume         # resume latest session
./tether -r -w ~/proj -m o3
./tether --version        # print version and exit
./tether --debug          # verbose logging
```

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
- **`load` removed**: JSON parsing uses `string.gmatch` patterns, never `load("return " .. s)`
- **Shell injection**: `tools.run` uses `env TETHER_WORKSPACE=<dir> sh -c` with `timeout`

## Testing

- `luac -p` validates all Lua modules on every `make test`
- `tests/lua_tests.lua` — unit tests for json_encode, parse_json_str, path resolution, glob matching
- `tests/host_smoke.sh` — end-to-end pipe/EOF tests
