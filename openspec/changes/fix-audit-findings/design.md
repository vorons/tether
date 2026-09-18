# Design: fix-audit-findings

## Context

`tether` is a single Lua+C binary. The audit (see the change proposal) found
seven defects plus several consistency issues, each confirmed by reading the
code and, for four of them, by running a minimal Lua harness against the real
modules. `make test` is fully green today, which means the gaps are in test
coverage rather than in flaky checks — see `tests/lua_tests.lua`,
`tests/context_tests.lua`, `tests/context_e2e.sh`, `tests/host_smoke.sh`.

Relevant current state:

- `agent.lua` owns history/journal, tool dispatch and the confirmation queue.
  The tool-result path is `run_tool_call → M.add_tool_result` (`agent.lua`),
  where `add_tool_result` reads only `result.content or result.error`.
- `tools.lua` resolves paths through `current_workspace(cfg)` but
  `read`/`list`/`glob`/`grep` are called without `cfg`; they fall back to
  `args._cfg`, which is never assigned anywhere in `src/`.
- `agent` inserts tool-call assistant messages as `{role="assistant",
  tool_calls=...}` with no content; `providers/openai.lua` hardcodes
  `"content":null` for that shape.
- `config.load` deep-merges `~/.tether/config.lua` and resolves provider keys,
  but never touches `~/.tether/auto_approve.lua`.
- `session.lua` lists sessions with GNU `find -printf '%T@ %p'`.
- `providers/common.lua` already holds `jesc`, `json_unescape`, `json_encode`;
  `agent.lua` and `session.lua` each carry a private `json_parse`, and `agent.lua`
  carries a duplicate `sse_unescape`.

## Goals / Non-Goals

**Goals:**

- Make every audit finding reproducible as a failing test first, then fix it.
- Keep the fixes local: no new external dependency, no wire-format change, no
  breaking config change.
- Keep the module-load contract of the embedded binary intact (the C host loads
  a fixed module list in a fixed order).

**Non-Goals:**

- Reworking the TUI layout, provider adapters, or the session schema.
- Adding a real tokenizer, PTY support, or new tools.
- Changing the journal format: `tool_result` stays summary-only (sessions spec);
  only the in-memory history carries the body.

## Decisions

### D1 — Forward the tool body through the existing `tool_body` helper

`agent.run_tool_call` already computes `tool_body(name, res)` for the UI event.
Pass that body into `add_tool_result` as `{content = body}` (and `{error = ...}`
on failure) instead of handing over the raw result table.

- *Why*: the body-extraction logic already exists and is provider-agnostic; the
  raw table only happens to expose `.content` for `read`.
- *Alternatives*: teach `encode_messages` to flatten each result shape — rejected,
  three adapters would need the shape map; enlarge `add_tool_result` to know tool
  names — rejected, it would leak the tool list into history code.
- *Safety*: forward at most a documented maximum (planned 16 KiB) with a
  `…(truncated)` marker, mirroring the AGENTS.md cap, so a single `run` cannot
  blow the context window.

### D2 — Pass `cfg` into the read tools; stop using `args._cfg`

Change `tools.read/list/glob/grep` to `(args, cfg)` and call them with `cfg`
from `agent.execute_tool`, matching `write`/`patch`/`run`. Remove the `_cfg`
fallbacks.

- *Why*: `tools.write`/`run` already take `cfg`, so this is the project's own
  convention; `_cfg` is a dead channel that made two resolution rules coexist.
- *Alternatives*: set `args._cfg = cfg` in `execute_tool` — rejected as hidden
  coupling and still leaves the misleading signatures in place.

### D3 — `agent.turn` stays the single entry point for the user message

In print mode, delete the standalone `agent.add_user(prompt)` in `app.lua` and
let `agent.turn` add and journal the user message (as the interactive path does).

- *Why*: one code path for "user message lands in history + journal".
- *Alternatives*: pass `skip_user = true` to `turn` from `app.lua` — rejected,
  it keeps two ways to do the same thing and the skip flag has no other caller.

### D4 — `config` owns auto-approve loading

Add a `load_auto_approve()` step to `config.load` that `loadfile`s
`~/.tether/auto_approve.lua`, tolerates a missing/invalid file, and appends its
patterns to `cfg.auto_approve` after the deep merge. `agent.persist_auto_approve`
keeps writing the same file (unchanged format).

- *Why*: the config spec already assigns load-time merge to the config layer,
  and the writer keeps the in-memory list in sync for the current session.
- *Alternatives*: read the file lazily inside `check_auto_approve` — rejected,
  it would hit the disk on every tool call.

### D5 — Extract the patch target for the confirmation policy

Add a small helper in `agent.lua` that scans the diff for the `+++ b/<path>`
header (falling back to `--- a/<path>`), resolve it against the workspace, and
use that in `should_confirm`. Align `tools.patch`'s out-of-workspace refusal to
the shared `... requires confirmation` wording.

- *Why*: the agent-core spec already requires `patch` to be confirmable; the
  target must be known before `tools.patch` runs.
- *Alternatives*: let `tools.patch` signal "needs confirmation" back to the agent
  — rejected, the agent would have to re-run the tool after approval and the
  patch would be parsed twice.

### D6 — One shared JSON implementation

Extend `providers/common.lua` (already embedded, already the shared pure-helpers
module) with `json_decode` (the recursive-descent parser) and have `agent.lua`
and `session.lua` use `common.json_decode` / `common.json_encode` /
`common.json_unescape`. Delete the copies.

- *Why*: removes ~150 duplicated lines and the risk of the parsers drifting.
- *Load order*: the C host loads modules in a fixed order (`session`, `ui`,
  `config`, `tools`, then providers, `api`, `context`, `agent`, `app`), so
  `session` and `agent` cannot rely on the `provider_common` global. Reorder the
  host list to load `provider_common` first, and keep the `loadfile(...)` fallback
  already used by `openai.lua` so `lua`-run tests still work. Update
  `tools/embed.lua`'s Makefile list only if the module set changes (it does not).
- *Alternatives*: a new `src/tether/json.lua` — rejected only to avoid touching
  the embed list and load order more than necessary; if the module grows beyond
  JSON helpers, splitting later is cheap.

### D7 — Portable session listing

Replace `find ... -printf '%T@ %p'` with a portable pipeline:
`find <dir> -name '*.jsonl' -type f`, ordered by mtime via
`ls -1t` (supported by both GNU and BSD/macOS `ls`). `session_files` keeps
returning `{id, mtime, ts, first_line}`; `mtime` stays best-effort (order rank)
because the picker only renders `ts` and `first_line`.

- *Why*: macOS is a documented target platform (design §3).
- *Alternatives*: `stat` — rejected, its flags differ between GNU and BSD; a Lua
  file-stat shim — rejected, more code than a portable `ls -t`.

### D8 — Assistant text with tool calls is kept

`agent.main_loop` writes the accumulated `text_acc` into the assistant
tool-call message when it is non-empty, and `providers/openai.lua` emits
`"content":"<escaped text>"` (still `null` when empty) for that shape; the
Anthropic/Gemini converters pass the text through as their text block/part.

- *Why*: matches the OpenAI contract and stops dropping visible reasoning.
- *Risk*: provider adapters must agree; covered by adapter unit tests.

### D9 — Small consistency fixes

- `read`: stop emitting the phantom trailing line for `\n`-terminated files.
- `openai.parse_sse_line`: surface `error.message` (real text) instead of the
  raw `error` fragment.
- `api.header_file`: create the file, `chmod 600`, then write the key, removing
  the world-readable window.
- `/copy` toast: include the target size (`✓ скопировано <size>`), matching the
  `tui` spec.
- `run`: format the timeout defensively so a non-integer value from the model
  cannot raise inside `string.format`.
- `context.lua`: quote the directory argument in the `ls` exec (same `sq`
  escaping used by `tools.lua`) and drop the stale "no io.popen" comment if the
  embedded runtime does expose it.

## Risks / Trade-offs

- [Forwarding full tool bodies grows context] → documented truncation cap (16 KiB)
  plus the existing context compressor.
- [Reordering the C host module list can break the global wiring] →
  `provider_common` has no dependencies; keep the `loadfile` fallback and run
  `make && make test` (host smoke + e2e) after the change.
- [JSON dedup touches the hot path for every streamed argument] → migrate one
  caller at a time and keep `tests/lua_tests.lua`'s parse cases green before
  deleting each copy.
- [Patch target extraction handles only `a/`/`b/` headers] → fall back to the
  pre-change behavior (workspace containment on the whole diff) when no header
  is found, and cover `/dev/null` new-file diffs in tests.
- [Portable `ls -1t` ordering is coarser than epoch mtime] → acceptable because
  the picker shows the first-event `ts`, not `mtime`.
- [Keeping assistant content with tool calls changes request bodies] → verify all
  three adapters still encode `content: null` when there is no text, so
  no-text tool turns are byte-identical.

## Migration Plan

1. Add failing tests first (one per finding), then apply fixes.
2. Land in priority order: P0 (D1, D2, D3) → P1 (D4, D5, `is_dir`) → P2 (D6–D9)
   → P3 docs/spec text.
3. After each priority, `make test` must stay green; the P0 set is independently
   shippable.
4. No data migration: `auto_approve.lua` and sessions keep their formats. Rollback
   is a revert; no persistent state is upgraded.

## Additional findings discovered during apply

- **`tools.patch` could never run (fixed, bonus).** The body wrapped
  `patch_str:gmatch(...)` in `ipairs(...)`, so the very first call raised
  `attempt to index a function value`. No test exercised the tool directly.
  Fixed in `src/tether/tools.lua` and covered by T112.
- **OpenAI SSE error bodies (fixed, bonus).** `parse_json_str` never kept nested
  objects, so `obj.error` was always nil and the `error` branch was dead. It now
  detects `"error"` in the payload and reports `error.message` (T108).

## Verify follow-up

- **External SIGINT (fixed).** The `host` delta required an externally delivered
  SIGINT to restore the terminal, but `main.c` only handled SIGTERM/SIGWINCH and
  installed handlers in tty mode only. `on_exit_signal` now covers SIGINT too and
  `setup_signal_handlers()` runs in every mode (the restore is a no-op when raw
  mode was never enabled). Covered by the new `tests/host_smoke.sh` SIGINT check;
  in-terminal Ctrl+C is unchanged (raw mode disables ISIG, so it arrives as byte
  `0x03`).

## Follow-up resolved

- **`a/` `b/` diff prefixes (D10).** `tools.patch` applies the `+++` path
  verbatim, so a git-style `+++ b/src/a.lua` header used to target
  `<workspace>/b/src/a.lua`, while the confirmation path (D5) stripped the
  prefix — the two disagreed. Both now strip one leading `a/`/`b/` component and
  treat `/dev/null` as a missing side, so git-style and prefix-less headers
  target the same file. Covered by T112.

## Open Questions

None.
