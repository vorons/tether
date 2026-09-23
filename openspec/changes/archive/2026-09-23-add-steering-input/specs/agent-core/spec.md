# Spec Delta

## MODIFIED Requirements

### Requirement: User message is journaled
The agent SHALL append the user text to history and SHALL WRITE a `message` event (role user) to the session journal before the LLM call. A steering message injected at a segment boundary and a follow-up message starting a new turn after settle SHALL be journaled the same way at the moment they enter history. Steering injection SHALL NOT re-add the original turn's user text and SHALL NOT insert a second system prompt.

#### Scenario: Turn with user text
- **WHEN** `agent.turn(cfg, key, "hi", ...)` runs
- **THEN** the session journal contains a `{type:"message", role:"user", content:"hi"}` event

#### Scenario: Steering message is journaled once
- **WHEN** a steering message is injected after a tool step
- **THEN** the journal has exactly one user `message` event for that text and history contains it once

#### Scenario: No double system prompt on steer
- **WHEN** steering injects a user message mid-turn
- **THEN** history still has exactly one system message at index 1
