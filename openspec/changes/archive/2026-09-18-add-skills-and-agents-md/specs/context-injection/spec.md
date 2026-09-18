# Spec Delta

## Purpose

System prompt assembly: defines how tether composes the effective system prompt from the built-in tool description, project/user instruction files (AGENTS.md), and the discovered skills index, and how each source is discovered.

## ADDED Requirements

### Requirement: AGENTS.md auto-discovery

The effective system prompt SHALL include the contents of `AGENTS.md` found at the workspace root and at the user's home directory (`$HOME/AGENTS.md`), when present. Home-directory content SHALL be included before workspace content. A file that exists but cannot be read SHALL be skipped with a warning to stderr, not an error.

#### Scenario: workspace AGENTS.md included

- **WHEN** a session starts in a workspace containing an `AGENTS.md` file and no home `AGENTS.md`
- **THEN** the workspace `AGENTS.md` content is appended to the system prompt after the built-in tool description

#### Scenario: both home and workspace present

- **WHEN** both `$HOME/AGENTS.md` and `<workspace>/AGENTS.md` exist
- **THEN** the prompt contains home content first, then workspace content, each under a labeled section

#### Scenario: no AGENTS.md anywhere

- **WHEN** no `AGENTS.md` exists at the workspace root or in `$HOME`
- **THEN** the system prompt contains no AGENTS.md section (behavior unchanged from before this capability)

### Requirement: --agents-file flag

The `--agents-file <path>` CLI flag SHALL append the named file's content to the system prompt. The flag SHALL be repeatable; files are appended in the order given. An unreadable path SHALL print `tether: cannot read agents file: <path>` to stderr and be skipped. The flag does not disable AGENTS.md auto-discovery. Agents-file content SHALL appear after the AGENTS.md auto-discovery sections and before the skills index. The config key `agents_files` (list of file paths, default `{}`) SHALL be treated identically to `--agents-file` values: entries are appended in list order before any `--agents-file` entries, with the same warning behavior for unreadable paths.

#### Scenario: flag used with missing file

- **WHEN** the user passes `--agents-file` with a path that does not exist
- **THEN** a warning is printed to stderr and the flag is otherwise ignored; the session continues

#### Scenario: config agents_files entries

- **WHEN** `~/.tether/config.lua` sets `agents_files = {"/a.md", "/b.md"}` and the user passes `--agents-file /c.md`
- **THEN** the prompt's agents-file section contains `/a.md`, then `/b.md`, then `/c.md` in that order

### Requirement: Skill directory discovery

tether SHALL discover skill directories by scanning, in order, the default locations: `~/.tether/skills/`, `<workspace>/.tether/skills/`, `~/.agents/skills/`, `<workspace>/.agents/skills/`. A skill SHALL be any immediate subdirectory of a discovered skills directory containing a `SKILL.md` file. Directories without `SKILL.md` SHALL be ignored. Duplicate skill names across directories are resolved first-wins in discovery order. The config key `skills_dirs` (list of directory paths) SHALL, when set, replace the default discovery list.

#### Scenario: skill found in workspace

- **WHEN** `<workspace>/.tether/skills/my-skill/SKILL.md` exists
- **THEN** the skill appears in the skills index with its name and description

#### Scenario: no skills anywhere

- **WHEN** no default skills directory exists and `skills_dirs` is unset
- **THEN** the system prompt contains no skills section

### Requirement: Skills index in system prompt

The effective system prompt SHALL include a skills section listing every discovered skill: its `name`, its `description` (from `SKILL.md` YAML frontmatter), and its file path, so the agent can read the full `SKILL.md` via the `read` tool on demand. Full skill content SHALL NOT be injected into the prompt automatically. A `SKILL.md` without frontmatter or with a missing `description` field SHALL be listed with its name and path and an empty description.

#### Scenario: skill index content

- **WHEN** two skills are discovered, one with `name: deploy` / `description: Ship the app` and one without frontmatter
- **THEN** the prompt's skills section lists both, the first with its description, the second with an empty description and both with their `SKILL.md` paths

### Requirement: Prompt composition order

The effective system prompt SHALL be composed in this order: (1) built-in tool description, (2) home AGENTS.md, (3) workspace AGENTS.md, (4) agents-file content (`cfg.agents_files` list order, then `--agents-file` flag order), (5) skills index. A `config.system_prompt` value, when set, SHALL replace only the built-in tool description (section 1), not the AGENTS.md, agents-file, or skills sections.

#### Scenario: config system_prompt overrides built-in

- **WHEN** `config.system_prompt` is set to custom text and an AGENTS.md and one skill exist
- **THEN** the prompt is: custom text, then AGENTS.md sections, then skills index
