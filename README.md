# tether

> Alpha version under active development. It may contain bugs.

Terminal-based AI coding agent in a single Lua + C binary. Think Claude Code or
Codex CLI, but the whole thing — agent loop, tools, TUI and in-process HTTPS — is
one self-contained executable that links only `libc` and `libm`.

## What it does

`tether` runs an LLM coding agent in your terminal: it reads, writes and searches
your project, applies patches, runs shell commands, and asks before doing
anything destructive. Everything happens inside a workspace; actions outside it
need an explicit confirmation. Sessions are journaled to disk, so a run can be
resumed where it stopped.

## Capabilities

- **Tools**: `read`, `list`, `glob`, `grep` (vendored krep engine, respects
  `.gitignore`), `write`, `patch` (unified diffs), `run` (shell via `/bin/sh`),
  `ask` (structured questions to the user) and `subagent` (parallel child runs).
- **Providers**: OpenAI-compatible, Anthropic and Gemini wire protocols plus
  adapters for Azure OpenAI, Amazon Bedrock, Google Vertex, Cloudflare AI
  Gateway, Radius and OpenAI Codex. Local-first by default (`llama-cpp`, `ollama`,
  `lmstudio`); 200+ cloud providers arrive through a synced catalog. Credentials
  come from env vars or an in-app `/login` — never from argv.
- **Steering**: `AGENTS.md` files and discoverable skills (`SKILL.md`) are folded
  into the system prompt at session start.
- **Sessions**: JSONL journal under `~/.tether/sessions/`, resumable with `-r` or
  the `/resume` palette.
- **TUI**: streaming transcript with markdown-lite rendering, syntax-highlighted
  code blocks, unified-diff previews, mouse scrolling, slash palette, per-project
  input history and OSC-52 clipboard. Degrades to ASCII on `TERM=dumb`/`NO_COLOR`.

## Build

Requirements: a C compiler, `ar`, and a `lua` interpreter (used by the embed
generator at build time only). All libraries — Lua 5.4.6, libcurl, mbedTLS, zlib
and krep — are vendored; nothing is downloaded during the build.

```sh
make          # build the tether binary (~40 s from scratch)
make test     # luac + lua unit tests + context e2e + host smoke + C primitives
make clean    # wipe build artifacts
```

`make test` additionally needs `luac`; the TLS test uses `openssl s_server` and
skips itself when the CLI is absent.

## Install

There is no `make install` target; just build and copy the binary somewhere on
your `PATH`:

```sh
make && sudo cp tether /usr/local/bin/
```

The binary is self-contained — `ldd tether` shows only `libc` and `libm` — so it
also runs fine straight out of the build directory or from a USB stick. Point
`TETHER_HOME` at a directory to keep `~/.tether` somewhere else (portable
installs, test isolation).

## First run

```sh
tether                       # interactive TUI in the current directory
tether --workspace ~/myproj
tether --print "prompt"      # non-interactive one-shot; or pipe stdin
tether --resume              # resume the latest session for this workspace
tether --model claude-opus-4-6
tether --agents-file ./rules.md   # extra instructions; repeatable
tether --version
```

Without a config the default provider is `llama-cpp` (a local llama.cpp server).
To use a cloud provider, set its key env var or run `/login` in the TUI, and pick
it in `~/.tether/config.lua`:

```lua
-- ~/.tether/config.lua
return {
  provider = "anthropic",
  providers = {
    anthropic = { api_key_env = "ANTHROPIC_API_KEY", model = "claude-sonnet-4-6" },
  },
}
```

## License

MIT. See `LICENSE`.
