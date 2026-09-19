# Spec Delta

## MODIFIED Requirements

### Requirement: Session picker data
`session_files(workspace)` SHALL return, per matching session, `{id, mtime, ts, first_line}` where `first_line` is the first user `message` content (the picker preview) and `mtime` is the recency rank (1 = newest). The listing SHALL enumerate the `*.jsonl` files under the session directory and order them by modification time descending, with ties broken by id for determinism, and SHALL be limited to the 100 most recent files. The listing SHALL be obtained through the in-process `tether.readdir` and `tether.stat` primitives — no `find`, `ls -1t` or `head` shell pipeline.

#### Scenario: Picker preview
- **WHEN** a session's first user message is "fix the login bug"
- **THEN** the picker row shows that text as the preview

#### Scenario: Listing is ordered by mtime
- **WHEN** the session directory holds more sessions than the picker cap
- **THEN** only the 100 most recent are returned, ordered newest first with `mtime` as the 1-based rank

#### Scenario: No shell pipeline
- **WHEN** the listing runs
- **THEN** it spawns no `find`/`ls`/`head` process and reads the directory through `tether.readdir` and `tether.stat`
