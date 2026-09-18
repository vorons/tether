# Tasks

## 1. P0 — correctness blockers

- [x] 1.1 Add a failing end-to-end test in `tests/lua_tests.lua` that drives `agent.turn` with a stubbed `api` emitting a `run` tool call and asserts the `tool` history message content is the tool body; verify it fails on the current code
- [x] 1.2 Fix `agent.run_tool_call`/`M.add_tool_result` to forward `tool_body(name, res)` (or the error text) with a 16 KiB truncation marker; verify the 1.1 test passes and the `read` body is unchanged
- [x] 1.3 Change `tools.read/list/glob/grep` to take `(args, cfg)` and call them with `cfg` from `agent.execute_tool`; verify a new test resolves a relative path against `cfg.workspace` while the process cwd differs
- [x] 1.4 Remove the `args._cfg` fallbacks from `tools.lua` and update any remaining callers; verify `rg "_cfg" src/` only shows intentional hits (none) and `make test` is green
- [x] 1.5 Delete the redundant `agent.add_user(prompt)` in `app.lua` print mode; verify a new test asserts exactly one user message in history/journal for `--print`
- [x] 1.6 Run `make test` and verify all four stages pass with the P0 set applied

## 2. P1 — functional regressions

- [x] 2.1 Load `~/.tether/auto_approve.lua` in `config.load` (tolerating missing/invalid) and merge into `cfg.auto_approve`; verify a test writes the file and asserts the pattern is present after a fresh load
- [x] 2.2 Extract the patch target path from the `+++ b/`/`--- a/` headers in `agent.should_confirm`; verify tests cover out-of-workspace (confirmation emitted) and in-workspace (no confirmation)
- [x] 2.3 Align `tools.patch`'s out-of-workspace refusal with `... outside workspace requires confirmation`; verify the error string test
- [x] 2.4 Fix the `tools.is_dir` probe; verify a test runs the real `tools.path_complete` against a temp directory tree and asserts a directory candidate carries a trailing `/` and a second completion lists inside it
- [x] 2.5 Run `make test` and verify all stages pass with the P1 set applied

## 3. P2 — minor fixes and refactor

- [x] 3.1 Replace the GNU `find -printf` session listing with a portable `find` + `ls -1t` pipeline; verify `session_files`/`latest` still order by mtime on a fixture and no `-printf` remains in `session.lua`
- [x] 3.2 Keep assistant text alongside tool calls in `agent.main_loop`; verify `openai.encode_messages` emits `"content":"..."` when text is present and `null` when empty, and the Anthropic/Gemini converters pass the text through
- [x] 3.3 Remove the phantom trailing line from `tools.read`; verify `line_count` and the last output row match the file's real line count
- [x] 3.4 Surface the real provider error message in `openai.parse_sse_line`; verify the error event message is the `error.message` text, not a raw fragment
- [x] 3.5 Make `api.header_file` create the temp file, `chmod 600`, then write the key; verify a test asserts the mode is 600 before the key is written and both temp files are removed
- [x] 3.6 Include the copied size in the `/copy` toast; verify the frame contains `✓ скопировано <size>` (ASCII `[ok] скопировано <size>`)
- [x] 3.7 Format `tools.run`'s timeout defensively so a non-integer/string value cannot raise; verify with a float/string timeout test
- [x] 3.8 Quote the directory in `context.lua`'s `ls` exec with the shared shell-quoting helper and drop the stale io.popen comment if the embedded runtime exposes it
- [x] 3.9 Move the recursive-descent JSON parser into `providers/common.lua`, wire `agent.lua`/`session.lua` to it, reorder the C host module list so `provider_common` loads first, and keep the `loadfile` fallback; verify `make test` (including host smoke and e2e) is green and the duplicated parsers are deleted
- [x] 3.10 Run `make test` and verify all stages pass with the P2 set applied

## 4. P3 — docs and spec sync

- [x] 4.1 Update `docs/design.md` (host API names `is_tty`, EOF contract, embed module list, AGENTS.md cap wording, `/copy` toast, auto-approve load) and `README.md`/`docs/tech-spec.md` where they name the same behavior
- [x] 4.2 Run `openspec validate fix-audit-findings --strict` and verify it passes
- [x] 4.3 Run `make test` one final time and verify the whole suite is green

## 5. Follow-up: a//b/ patch prefixes

- [x] 5.1 Strip one leading `a/`/`b/` component in `tools.patch` and in the agent's patch-policy target and treat `/dev/null` as a missing side; verify T112 covers git-style, prefix-less and new-file headers and `make test` is green

## 6. Verify follow-up: external SIGINT

- [x] 6.1 Install the SIGINT handler alongside SIGTERM (in every mode, not only the tty) so an external signal restores the terminal and exits 0, and add a `tests/host_smoke.sh` check; verify `make test` is green
