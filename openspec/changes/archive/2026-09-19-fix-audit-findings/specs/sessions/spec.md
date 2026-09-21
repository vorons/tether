# Spec Delta: sessions

## ADDED Requirements

### Requirement: Portable session listing

Listing session files for resume SHALL rely only on POSIX-standard
facilities available on every supported platform (Linux and macOS), and
SHALL NOT depend on GNU-only `find` extensions. On a platform without
those extensions the picker data and `latest(workspace)` SHALL still
return the matching sessions.

#### Scenario: GNU find extensions unavailable
- **WHEN** the host `find` does not support `-printf` (e.g. BSD/macOS)
- **THEN** `session_files` and `latest` still return sessions for the workspace, ordered by mtime descending

#### Scenario: Resume works on the same platform
- **WHEN** the user passes `-r` on a platform without GNU `find -printf`
- **THEN** the latest matching session is found and its messages restored
