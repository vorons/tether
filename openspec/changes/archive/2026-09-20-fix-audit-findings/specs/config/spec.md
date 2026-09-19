# Spec Delta: config

## MODIFIED Requirements

### Requirement: Auto-approve persistence file
`[A] always` confirmations SHALL be persisted to
`~/.tether/auto_approve.lua` as a Lua table of anchored
`^tool:path$` patterns with a dated comment header. The file SHALL
be deduplicated (same pattern not appended twice) and SHALL be
merged into `cfg.auto_approve` on next load. Loading SHALL tolerate a
missing or unreadable file by contributing no patterns and SHALL NOT
fail the session.

#### Scenario: Second always is a no-op
- **WHEN** the same key is chosen always twice
- **THEN** the file contains the pattern once

#### Scenario: Persisted patterns load on next start
- **WHEN** `~/.tether/auto_approve.lua` holds `^run:/tmp/x$` and a new process loads the config
- **THEN** `cfg.auto_approve` contains that pattern and a later `run` with cwd `/tmp/x` skips confirmation

#### Scenario: Missing persistence file
- **WHEN** `~/.tether/auto_approve.lua` does not exist
- **THEN** loading succeeds with `cfg.auto_approve = {}`
