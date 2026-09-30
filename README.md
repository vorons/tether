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

```sh
sudo make install                    # /usr/local/bin/tether
make install PREFIX=$HOME/.local     # no root; ~/.local/bin/tether
make install DESTDIR=$PWD/pkg        # stage into a tree, don't touch the system
```

`make install` builds the binary first (so `make release && make install`
installs the optimized one), then copies it to `$(DESTDIR)$(PREFIX)/bin`.

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
tether update                  # replace this binary with the newest release
```

Releases are named by the short git sha of the commit they were built from, and
`tether --version` prints that sha. On an interactive start (a terminal on stdin, not
`--print` or piped input) tether looks at a cached result of its last release probe
(`~/.tether/update.json`) and, when it holds a different sha, shows one dim row under
the splash telling you to run `tether update`. The probe itself runs detached in the
background, so startup never waits on the network; a failed or slow probe is invisible.
Set `update_check = false` in `~/.tether/config.lua` to skip both the probe and the
banner — the command keeps working, since an explicit `tether update` needs no opt-in.
`tether update` needs write access to the directory holding the running binary — for a
root-owned `/usr/local/bin` install run it with `sudo`, or reinstall under `$HOME/.local`
with `make install PREFIX=$HOME/.local`. A binary built before this feature has no
`update` verb (it reads the word as a workspace path), so that first hop has to be the
manual one: download the release tarball or `make install`.

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
