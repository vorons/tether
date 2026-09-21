# Spec Delta

## MODIFIED Requirements

### Requirement: Path completion
With `ui.path_completion` on (default) and a non-empty input, pressing
Tab outside an open palette SHALL complete the workspace-relative
path token under the cursor against the workspace contents:

- Exactly one candidate SHALL complete the token in place without
  opening the palette, leaving any text that follows the token unchanged.
- Several candidates SHALL open the palette listing them, with the
  first candidate applied to the token so the user sees the current
  choice, and each further Tab press SHALL move to the next candidate
  and apply it, wrapping at the end of the list.
- Directory candidates SHALL be completed with a trailing `/` so that
  completing again lists inside them.
- Esc SHALL close the completion palette and restore the token exactly
  as typed before the first completion.
- Completion SHALL leave the cursor immediately after the text it
  applied: directly after the applied candidate, or directly after the
  token restored by Esc, and in both cases before any text that
  follows the token. The cursor SHALL NOT be placed past the end of
  the input.
- With no candidate the input SHALL be left unchanged and no palette
  SHALL open.
- Candidates SHALL be limited to the workspace: absolute paths, `~`
  and `..` tokens SHALL NOT be completed, and no candidate outside the
  workspace SHALL be listed.
- Hidden entries (a leading `.`) SHALL be offered only when the typed
  token itself starts with `.`.
- The candidate list SHALL be capped at 200 entries; when the cap
  truncates the list the palette SHALL indicate that more candidates
  exist.
- Completion SHALL NOT send anything to the agent and SHALL NOT alter
  the agent history.
- With `ui.path_completion` false, Tab outside the palette SHALL be a
  no-op, as before.

#### Scenario: Unique candidate completes in place
- **WHEN** the input holds `read src/tether/ag` and `src/tether/agent.lua` is the only match
- **THEN** the token becomes `src/tether/agent.lua` and no palette opens

#### Scenario: Text after the token survives a unique completion
- **WHEN** the input holds `read src/tether/ag.bak` with the cursor directly after `ag`, and `src/tether/agent.lua` is the only match
- **THEN** the input becomes `read src/tether/agent.lua.bak` with the cursor directly after `src/tether/agent.lua`, so the next Backspace deletes its last character

#### Scenario: Cursor follows the applied candidate
- **WHEN** the input holds `read src/tether/ag` with the cursor at the end and Tab completes the token
- **THEN** the cursor sits directly after `src/tether/agent.lua`, so the next Backspace deletes its last character

#### Scenario: Cursor follows a cycled candidate
- **WHEN** several candidates exist and the user presses Tab twice
- **THEN** the cursor sits directly after the second candidate, not after any text that follows the token

#### Scenario: Cursor follows the restored token
- **WHEN** the user presses Tab on a token and then Esc
- **THEN** the token is restored and the cursor sits directly after it

#### Scenario: Directory gets a trailing slash
- **WHEN** the token matches exactly one directory `src`
- **THEN** the token becomes `src/`

#### Scenario: Several candidates cycle
- **WHEN** two files match and the user presses Tab twice
- **THEN** the palette lists both and the token holds the second candidate

#### Scenario: Esc restores the typed token
- **WHEN** the user presses Tab on a token, then Esc
- **THEN** the token is exactly what was typed before the Tab press

#### Scenario: Hidden entries need a dot
- **WHEN** the token is `s` and the workspace holds `src` and `.secrets`
- **THEN** only `src` is offered

#### Scenario: Outside the workspace is not completed
- **WHEN** the token is `../etc/pass` and the workspace has no matching entry
- **THEN** the input is unchanged and no candidate outside the workspace is listed

#### Scenario: Disabled
- **WHEN** `ui.path_completion` is false and the user presses Tab outside the palette
- **THEN** the input and the palette state are unchanged
