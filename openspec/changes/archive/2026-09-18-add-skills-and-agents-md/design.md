# Design

## Context

System prompt assembly lives in two places today: the built-in prompt string is a module-level local in `src/tether/agent.lua` (`system_prompt`, line ~9), and the override path is `config.get_system_prompt(cfg)` in `src/tether/config.lua` (inline text, `/…` file path, or raw string). `agent.lua` inserts `history[1]` from `get_system_prompt` or falls back to the built-in. CLI flags are parsed in `src/tether/app.lua`; workspace resolution (`cfg.workspace`) already happens there before session start. Lua is embedded into the C host via `tools/embed.lua` — the Makefile passes exactly seven application modules, so any new module needs a Makefile + embed entry.

Constraints: single binary, Lua 5.x stdlib only (no filesystem library beyond `io` and the shell-exec primitives the host exposes), no external dependencies. `context.lua` runs before the agent loop, so skill enumeration uses the C host's exec surface (`tether.exec`), not `io.popen` (which is not available in the embedded runtime).

## Goals / Non-Goals

**Goals:**
- Compose the prompt from: base (config `system_prompt` or built-in) + AGENTS.md (home, then workspace) + `--agents-file` contents + skills index.
- Discover skills by scanning default directories; honor `cfg.skills_dirs` override.
- Zero behavior change when no AGENTS.md / no skills exist.

**Non-Goals:**
- No full skill-content injection into the prompt (index only; agent reads `SKILL.md` on demand via `read`).
- No skill execution engine, no skill-level tool allowlists, no dynamic skill loading mid-session.
- No YAML parser dependency — frontmatter is parsed with plain string matching (`name:` / `description:` lines in a `---` block).

## Decisions

### New module `src/tether/context.lua`

Prompt assembly goes into a new module `context.lua` (8th embedded module):
- `context.compose(cfg, opts)` → full prompt string. `opts` carries `agents_files` (extra paths from the CLI flag) and `workspace`.
- `context.load_agents_files(workspace)` → `{ {label, content}, ... }` for `$HOME/AGENTS.md` and `<workspace>/AGENTS.md`.
- `context.discover_skills(cfg, workspace)` → `{ {name, description, path}, ... }`.
- `context.parse_skill_frontmatter(text)` → `{name, description}` from a `---`…`---` block; returns just the file-stem name when frontmatter is absent.

Rationale: keeps `agent.lua` (turn loop) and `config.lua` (config loading) untouched in their responsibilities; composition is a distinct concern with its own testable surface.

Alternative considered: fold into `config.lua`. Rejected — `config.lua` is the config-loading contract covered by the `config` spec; adding discovery + prompt assembly would bloat that spec's scope.

### AGENTS.md discovery

Order: `$HOME/AGENTS.md`, then `<workspace>/AGENTS.md`. Read via `io.open`; unreadable → stderr warning, skip. Content is wrapped in labeled sections:

```
## AGENTS.md (home)
<content>

## AGENTS.md (workspace)
<content>
```

The label makes multi-source provenance visible to the model.

### `--agents-file` semantics

Repeatable flag (`--agents-file a --agents-file b` → both appended, in order). Position in composition: **after** AGENTS.md auto-discovery sections, **before** the skills index (matching `context-injection` §Prompt composition order). Content gets the same labeled-section treatment: `## agents file: <path>`. Unreadable → `tether: cannot read agents file: <path>` on stderr, session continues.

`cfg.agents_files` (list, default `{}`) SHALL be concatenated before the CLI flag paths and fed to the same composition path: `cfg.agents_files` entries first (in list order), then `--agents-file` entries. This makes config a persistent alternative to the repeatable flag; both go into the same "agents files" section between AGENTS.md auto-discovery and the skills index. The `context-injection` spec covers the combined list as `--agents-file` content in flag order — config-level entries simply precede it in the final order.

### Skill discovery

Default dir list (first-wins on name collision):

1. `~/.tether/skills`
2. `<workspace>/.tether/skills`
3. `~/.agents/skills`
4. `<workspace>/.agents/skills`

`cfg.skills_dirs` (string list) **replaces** the default list when non-nil. Directories are enumerated with `tether.exec("ls -1A <dir>")` (the C host's exec, available at app start before the agent loop; `io.popen` is not available in the embedded runtime), newline-split, limited to immediate subdirectories; a subdir qualifies as a skill iff `SKILL.md` exists inside it. Missing directories are silently skipped (no default dirs exist on a fresh install).

Frontmatter parse: if the file starts with `---\n`, take lines up to the closing `---`; find the first `name:` and `description:` lines; strip quotes. No parser library — matches pi/Claude SKILL.md convention well enough.

### Skills index section

```
## Skills
Skills are markdown instruction files. When a task matches a skill's
description, read the full file with the `read` tool before acting.

- name: deploy
  description: Ship the app
  file: /path/to/.tether/skills/deploy/SKILL.md
```

One entry per discovered skill. No skills → section omitted entirely.

### Module registration

The Makefile passes exactly seven application modules today; this change adds an eighth (`context`); `app.lua` requires it and passes the composed prompt into `agent` (agent's fallback path is the composition result; `config.get_system_prompt` base resolution is unchanged).

## Risks / Trade-offs

- [AGENTS.md content unbounded → prompt bloat] → Cap: if total AGENTS.md content exceeds 16 KB, truncate with an `…(truncated)` marker; document in README.
- [`ls`-based skill enumeration breaks on names with whitespace] → Use `ls -1A` + newline splitting, same as existing `list` tool; skill dir names with newlines are not supported (documented limitation, consistent with the rest of the codebase).
- [Duplicate skills across dirs silently first-wins] → Acceptable: documented in README; collision is user configuration error.
- [New module changes the embedded-binary layout] → Low risk: `embed.c` regenerates; `make test` covers build.

## Migration Plan

Pure addition; no data migration. Rollback: remove `context.lua` + Makefile entry; `agent.lua` falls back to today's prompt path. Existing sessions and config files unaffected (new config keys default to empty).

## Open Questions

None — all material decisions (dir list, flag semantics, index-only injection) were fixed with the user during the request.
