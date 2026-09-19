# Spec Delta: tools

## MODIFIED Requirements

### Requirement: Workspace resolution

The workspace SHALL be `cfg.workspace` (or `TETHER_WORKSPACE` env),
resolved through `realpath` with symlinks expanded; the fallback is
the process cwd. Every tool — `read`, `list`, `glob`, `grep`, `write`,
`patch` and `run` — SHALL resolve relative paths and default
directories against that workspace, independently of the process cwd,
so `-w` and `config.workspace` apply uniformly.

#### Scenario: Symlinked workspace
- **WHEN** `-w` points at a symlinked directory
- **THEN** the effective workspace is the resolved real path, and
  containment checks use it

#### Scenario: read honors -w from another cwd
- **WHEN** the process runs in `/tmp` with `-w /ws` and calls `read` with `path = "src/a.lua"`
- **THEN** `/ws/src/a.lua` is read, not `/tmp/src/a.lua`

#### Scenario: listing and search honor -w
- **WHEN** the process runs in `/tmp` with `-w /ws` and calls `list`, `glob` or `grep` without an explicit path
- **THEN** they operate on the `/ws` tree

### Requirement: Outside-workspace guard

`write`, `patch` and `run` SHALL reject targets resolving outside the
workspace with the error `... outside workspace requires
confirmation` (the agent layer then asks the user); `allow_outside_workspace =
true` bypasses the guard entirely.

#### Scenario: allow_outside_workspace true
- **WHEN** the flag is set and write targets `/etc/hosts`
- **THEN** the tool executes without an error result

#### Scenario: patch outside workspace uses the same refusal text
- **WHEN** a patch targets a file outside the workspace and confirmation is not granted
- **THEN** the error names `requires confirmation`, matching `write` and `run` for the agent's policy check

### Requirement: Strict patch application

`patch` SHALL parse unified-diff files, resolve the target from the
`+++` header (falling back to `---`), apply hunks from last to first,
and require every old-line to match exactly at its declared position.
A single leading `a/` or `b/` component — the prefix `diff -u` and git
add to headers — SHALL be stripped and SHALL NOT become part of the
target path, so git-style headers (`--- a/x`, `+++ b/x`) and
prefix-less headers (`--- x`, `+++ x`) target the same file.
`/dev/null` SHALL mean the file is absent on that side (a new or
deleted file), not a literal path. On any mismatch the tool SHALL
fail with `patch conflict in <file> — перечитайте файл` and leave the
file untouched. Results SHALL report `{files, add, del, applied[]}`.

#### Scenario: Conflict leaves file intact
- **WHEN** a hunk's context lines no longer match
- **THEN** the tool returns the conflict error and the target file
  is not modified

#### Scenario: Git-style header targets the real path
- **WHEN** the diff carries `--- a/src/a.txt` and `+++ b/src/a.txt`
- **THEN** the change is applied to `src/a.txt`, not to `b/src/a.txt`

#### Scenario: Both header styles agree
- **WHEN** the same change is submitted once with `a/`/`b/` prefixes and once without them
- **THEN** both diffs modify the same file and produce the same result

#### Scenario: New file via /dev/null
- **WHEN** the diff carries `--- /dev/null` and `+++ b/new.txt`
- **THEN** the change is applied to `new.txt` and `/dev/null` is not treated as a path
