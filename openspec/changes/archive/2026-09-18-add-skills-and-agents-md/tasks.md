# Tasks

## 1. `src/tether/context.lua` module

- [x] 1.1 Create `context.lua` with `M.compose(cfg, opts)`, `M.load_agents_files(workspace)`, `M.discover_skills(cfg, workspace)`, `M.parse_skill_frontmatter(text)` (see design.md Decisions).
- [x] 1.2 AGENTS.md discovery: `$HOME/AGENTS.md` then `<workspace>/AGENTS.md`; unreadable → stderr warn, skip.
- [x] 1.3 Skill discovery: default dirs `~/.tether/skills`, `<ws>/.tether/skills`, `~/.agents/skills`, `<ws>/.agents/skills`; `cfg.skills_dirs` replaces defaults; subdir + `SKILL.md` = skill; first-wins on name collision.
- [x] 1.4 Frontmatter parse: `name:` / `description:` from a leading `---` block; missing frontmatter → name = dir name, description = "".
- [x] 1.5 Compose: base (`config.get_system_prompt` result or built-in tool prompt) + AGENTS.md labeled sections + agents-file sections (`cfg.agents_files` then `--agents-file`, in that order) + skills index section (omit when empty).
- [x] 1.6 16 KB AGENTS.md content cap with `…(truncated)` marker.

## 2. Wiring

- [x] 2.1 `app.lua`: parse repeatable `--agents-file <path>` flag; pass to `context.compose` via opts; `--help`/`--version` text updated.
- [x] 2.2 `agent.lua`: head-of-history system message uses the composed prompt; keep built-in prompt string as the base fallback.
- [x] 2.3 `Makefile` + `tools/embed.lua` invocation: add `context` as the 8th embedded module; `embed.c` regenerates.

## 3. Config

- [x] 3.1 `config.lua` defaults: `skills_dirs = nil`, `agents_files = {}` (agents_files populated at runtime from CLI flag, not persisted).

## 4. Tests

- [x] 4.1 `tests/lua_tests.lua` (or new `tests/context_tests.lua` + Makefile test target): agents file discovery order, missing-file warning, frontmatter parse (with/without), first-wins collision, `skills_dirs` override, compose ordering (AGENTS.md → agents_files → skills), 16 KB truncation.
- [x] 4.2 End-to-end check with a deterministic fixture: a scratch workspace containing `AGENTS.md` + one skill dir + a local HTTP stub as `base_url` (or `--debug` log capture) such that the recorded request's system message is diffed against a checked-in expected-prompt file; a mismatch fails the test. No manual eyeballing.

## 5. Docs

- [x] 5.1 `README.md`: AGENTS.md behavior, `--agents-file`, skills directories + `SKILL.md` format + `skills_dirs` config.
- [x] 5.2 `docs/design.md`: context-injection section matching the new spec.
