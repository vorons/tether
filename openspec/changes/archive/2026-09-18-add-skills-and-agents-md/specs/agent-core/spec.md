# Spec Delta

## MODIFIED Requirements

### Requirement: Agent turn installs the system prompt

The agent SHALL place a system-prompt message at the head of history before the first turn. The prompt SHALL be the composed prompt from context-injection (built-in tool description or `config.system_prompt` base, then AGENTS.md sections, then the skills index). When composition yields nothing beyond the base, the built-in default prompt SHALL be used.

#### Scenario: First turn with no custom prompt

- **WHEN** `agent.turn` runs and `cfg.system_prompt` is nil or empty, and no AGENTS.md or skills are discovered
- **THEN** history[1] is the built-in system prompt with tool listing

#### Scenario: Custom inline prompt

- **WHEN** `cfg.system_prompt` is a multi-line string and no AGENTS.md or skills are discovered
- **THEN** history[1] content equals that string

#### Scenario: Composed prompt in history

- **WHEN** a session starts with a workspace `AGENTS.md` and two discovered skills
- **THEN** `history[1]` is a system message containing the tool description, the `AGENTS.md` content, and the two-skill index
