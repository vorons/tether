# Tasks

## 1. Palette merge

- [x] 1.1 Add the skills candidate source in `src/tether/ui.lua`: move `M._skills_stub` above `palette_sync`, add `skill_rows()` (lazy discovery via `context.discover_skills`, cached on `S.skill_rows`, `pcall`-guarded, drops a row whose `/<name>` duplicates a `SLASH_COMMANDS` label); verify a test with a stubbed skill list returns rows labelled `/<name>` and one with an empty list returns none
- [x] 1.2 Extend `palette_sync()` to build one candidate list (commands, then skills) and rank it with the existing `fuzzy_rank`; verify an empty filter lists commands first followed by skills, and `/model` ranks `/model` above a `model-review` skill
- [x] 1.3 Handle the skill row in the command-palette Enter branch: set the input to `/<name> ` with the cursor at the end and close the palette; verify the palette is inactive afterwards and the input carries a trailing space

## 2. Remove the separate skills palette

- [x] 2.1 Delete the `/skills` entry from `SLASH_COMMANDS`, the `cmd == "skills"` branch of `execute_command`, `S._in_skills_palette`, its `palette_sync` guards and the `palette_mode == "skills"` branch of `handle_key`; verify `grep -rn "_in_skills_palette\|palette_mode == \"skills\"" src/` is empty
- [x] 2.2 Verify no `(нет скиллов)` placeholder remains and an empty discovery leaves the palette listing only commands

## 3. Submitted skill reference reaches the agent

- [x] 3.1 Restrict command dispatch in `commit_input` to names present in `SLASH_COMMANDS`; verify a submitted `/deploy ship it` reaches `agent.turn` once with that text, while `/model` still runs the command
- [x] 3.2 Reset the discovery cache in `start_new_session()`; verify `/new` clears `S.skill_rows`

## 4. Tests

- [x] 4.1 Rewrite T79 against the merged palette (commands + skills, `/name` labels with descriptions, no placeholder when empty, command/skill name collision, tie order)
- [x] 4.2 Rewrite T80 to assert Enter substitutes `/name ` (cursor at end, palette closed, no body and no `SKILL.md` path in the input)
- [x] 4.3 Rewrite T81: a submitted `/name task` reaches the agent exactly once and is not cleared as an unknown command, while `/copy` is still dispatched
- [x] 4.4 Add T113 (a submitted `/help me` is sent as a message rather than silently cleared) and T114 (palette select then submit, discovery cached once and invalidated by `/new`); make the T53 harness stub skill discovery so palette tests never scan the developer's `HOME`
- [x] 4.5 Update the T39/T69/T71 command-count assertions from eight commands to seven

## 5. Docs and spec sync

- [x] 5.1 Update `README.md` (command list, the `/skills` bullet) and `docs/design.md` (§6.8 command list, palette ordering, skill row, submit rule) to describe skills as rows of the main palette
- [x] 5.2 Run `openspec validate skills-in-main-palette --strict` and verify it passes
- [x] 5.3 Run `make test` and verify luac, unit, context, e2e and host smoke all pass

## 6. Follow-up found during apply

- [x] 6.1 Make the palette tests hermetic: `run_ui_with` injects a default empty `_skills_stub` (overridable with `stubs.skills`) so opening `/` never shells out to the real `$HOME` during a test run

## 7. Follow-up: the palette reported no skills in the built binary

- [x] 7.1 Reproduce against the real binary under a pty: the palette listed the seven commands and no skill row, even with `ws/.agents/skills/deploy/SKILL.md` present
- [x] 7.2 Replace `require("context")` with `embedded_module("context")` (global first, then `loadfile`, the `api.lua` convention) in `skill_rows`; verify T115 — a spy installed as the `context` global backs a `/spy-skill` row that exists nowhere on disk
- [x] 7.3 Apply the same resolution to `path_completion`'s tools lookup (`require("tools")` never resolved in the binary, so Tab completion was dead); verify T116 — a spy on the `tools` global drives a Tab completion through `handle_key`
- [x] 7.4 Fix `ui.run()` re-loading config and discarding `app.lua`'s table (`-w`, `-m`, `--debug`, `--agents-file`, `cfg._session_id`): take an optional prepared config and call `ui.run(cfg)` from `app.lua`; verify T117 (workspace/model/debug/session id come from the prepared config and `config.load` is not called again)
- [x] 7.5 Verify in the built binary under a pty: `-w /tmp/.../ws` from an unrelated cwd lists `/deploy` and shows the `-w` workspace in the status line; a skill under `~/.agents/skills` is listed too; one interactive start writes exactly one session file (previously two)
- [x] 7.6 Run `make test` and verify the whole suite is green with the resolution and config-handoff fixes
