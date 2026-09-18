# Proposal

## Why

tether's system prompt is hardcoded in `src/tether/agent.lua` with a single manual override (`config.system_prompt`). There is no way to give project-level instructions (AGENTS.md) or reusable task-specific skills (markdown skill files) to the agent. Competing agents (Claude Code, pi) auto-load `AGENTS.md` / `.pi/skills`; tether users must hand-edit the config file to get anything similar.

## What Changes

- Auto-include instruction files into the system prompt: read `AGENTS.md` from the workspace root and from `$HOME` (if present) and append their contents to the effective system prompt.
- New CLI flag `--agents-file <path>`: use a specific file instead of (or in addition to) the auto-discovered `AGENTS.md` files.
- Skills support: auto-discover skill directories in order `~/.tether/skills/`, `<workspace>/.tether/skills/`, `~/.agents/skills/`, `<workspace>/.agents/skills/`. Each skill is a directory containing a `SKILL.md`.
- A skill's `SKILL.md` frontmatter (`name`, `description`) is injected into the system prompt as a skill index (mirroring pi's behavior: agent sees skill names + descriptions, reads the full `SKILL.md` via the `read` tool on demand when a task matches).
- `config.skills_dirs` (list) can extend or override the default discovery order.
- Skill files are NOT auto-loaded in full — only index (name/description/path). Full content enters context only when the agent reads it with `read`, keeping the prompt small.

## Capabilities

### New Capabilities

- `context-injection`: system prompt assembly — how the effective system prompt is composed from the built-in default, `config.system_prompt`, AGENTS.md files, and the skills index; discovery rules for both AGENTS.md and skill directories.

### Modified Capabilities

- `config`: `get_system_prompt` requirement changes — the prompt is now composed from multiple sources (config override + AGENTS.md + skills index) rather than a single config value; new config keys `agents_files` and `skills_dirs`.
- `agent-core`: system-prompt placement requirement — the head-of-history system message is now the composed prompt (built-in + AGENTS.md content + skills index + config override), not just `config.get_system_prompt` or the default.

## Impact

- `src/tether/config.lua`: new `load_agents_files` / `load_skills` / composition logic, new config keys with defaults.
- `src/tether/agent.lua`: replace `system_prompt` usage with composed prompt (agent layer keeps only the built-in tool-descriptions part; composition moves to a new module or config.lua).
- `src/tether/app.lua`: `--agents-file` flag parsing.
- `docs/` + `README.md`: document AGENTS.md and skills directories.
- No provider/API changes. No breaking behavior: without AGENTS.md or skills present, the prompt is unchanged from today's default. Note: `config.system_prompt`, when set, now replaces only the built-in base — AGENTS.md and skills sections are still appended after it (previously a custom `system_prompt` was the entire prompt).
