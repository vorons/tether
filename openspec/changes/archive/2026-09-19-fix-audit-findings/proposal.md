# Proposal: fix-audit-findings

## Why

A spec-vs-code audit of `tether` found seven defects that break documented
behavior (not style nits): tool outputs never reach the model, `-w` is ignored
by the read tools, `--print` duplicates the user turn, `[A] always` is written
but never loaded, `patch` skips the confirmation policy, directory completion
never appends `/`, and session listing uses a GNU-only `find` flag so `-r`
silently finds nothing on macOS. `make test` stays green because none of these
paths is covered end-to-end, so they must be fixed together with the tests that
would have caught them.

## What Changes

- **Tool results are forwarded to the model (P0).** `agent.run_tool_call` sends
  the full tool body (not just `content`/`error`) into the `tool` history message,
  so `run`/`grep`/`glob`/`list`/`write`/`patch` outputs are visible to the LLM,
  not just `read`.
- **Workspace is honored by every tool (P0).** `read`/`list`/`glob`/`grep`
  receive `cfg` and resolve relative paths against `cfg.workspace`
  (`-w`/`config.workspace`), like `write`/`patch`/`run` already do.
- **`--print` sends the user message once (P0).** Remove the duplicate
  `agent.add_user` before `agent.turn`.
- **`[A] always` survives restarts (P1).** `config.load` reads and merges
  `~/.tether/auto_approve.lua` into `cfg.auto_approve`, per the config spec.
- **`patch` participates in the confirmation policy (P1).** The target path is
  extracted from the diff headers so an out-of-workspace patch raises the
  confirmation menu; the tool's own refusal message is aligned with
  `... outside workspace requires confirmation`.
- **Directory completion appends `/` (P1, code fix).** Fix the
  `tools.path_complete` directory probe so candidates that are directories are
  suffixed and a second Tab can descend into them, satisfying the existing
  `tui` path-completion requirement.
- **Portable session listing (P2).** Replace the GNU `find -printf` dependency
  in `session.lua` with a listing that also works on BSD/macOS, so `-r` and
  `/resume` work on a documented target platform.
- **Minor correctness and consistency fixes (P2).** Preserve assistant text
  emitted alongside tool calls; surface the real provider error message;
  drop the phantom trailing line from `read`; make the `/copy` toast match the
  TUI spec (`✓ скопировано <size>`); harden `run`'s timeout formatting; close
  the temp-file permission window in `api.lua`.
- **De-duplicate hand-rolled JSON (P2, refactor).** One shared JSON
  parse/encode/unescape implementation replaces the three parser copies and the
  two unescape copies (`agent.lua`, `session.lua`, `providers/common.lua`), with
  no behavior change.
- **Spec and doc sync (P3).** Align specs with the shipped surface:
  `tether.is_tty` (not `tty`), the EOF contract, the real embedded module list,
  the AGENTS.md cap wording, and the `/copy` toast.

## Capabilities

### New Capabilities
- None.

### Modified Capabilities
- `agent-core`: tool results carry their body to the model; `patch` is covered
  by the confirmation policy; assistant text emitted with tool calls is kept.
- `config`: the auto-approve persistence file is loaded and merged on startup.
- `tools`: workspace resolution applies to `read`/`list`/`glob`/`grep`; the
  outside-workspace guard names the confirmation message for `patch` too.
- `sessions`: session listing and resume are portable (no GNU-only flags).
- `host`: documented API name, EOF contract and embed module list match the C host.
- `api-client`: the auth header temp file is private from creation.

## Impact

- Code: `src/tether/agent.lua`, `config.lua`, `tools.lua`, `session.lua`,
  `app.lua`, `api.lua`, `providers/{openai,common}.lua`, `ui.lua`,
  plus a new shared JSON helper registered in `tools/embed.lua`.
- Tests: `tests/lua_tests.lua` (end-to-end tool-result content, workspace
  resolution, single print-mode user message, auto-approve load, patch
  confirmation, real `is_dir`/`path_complete`, portable listing), and the
  existing `context_e2e.sh`/`host_smoke.sh` stay green.
- Docs: `README.md`, `docs/design.md`, `docs/tech-spec.md`, and the affected
  `openspec/specs/*` files.
- No C host behavior change beyond spec text; no breaking config or wire-format
  change. Existing OpenAI installs behave identically.
