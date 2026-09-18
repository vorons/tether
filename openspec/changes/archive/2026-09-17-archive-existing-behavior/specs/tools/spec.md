# Spec Delta

## Purpose

File and shell tool execution: read/list/glob/grep/write/patch/run
with a strict workspace path policy.

## ADDED Requirements

### Requirement: Workspace resolution
The workspace SHALL be `cfg.workspace` (or `TETHER_WORKSPACE` env),
resolved through `realpath` with symlinks expanded; the fallback is
the process cwd. Relative tool paths SHALL resolve against the
workspace root.

#### Scenario: Symlinked workspace
- **WHEN** `-w` points at a symlinked directory
- **THEN** the effective workspace is the resolved real path, and
  containment checks use it

### Requirement: Read limits and binary rejection
`read` SHALL read at most 1 MiB, reject files containing a NUL byte
in the first 8 KiB as binary, cap iteration at 200000 lines, and
apply `offset` (default 1) and `limit` (default 10000). Output lines
SHALL be `lineno<TAB>content`.

#### Scenario: Binary file
- **WHEN** the target contains NUL in its first 8 KiB
- **THEN** the result is an error `<rel> is binary`

#### Scenario: Default window
- **WHEN** read is called without offset/limit on a 50000-line file
- **THEN** lines 1-10000 are returned, 1-indexed, tab-separated

### Requirement: Directory listing
`list` SHALL return the sorted entries of a directory (via
`ls -1A`), defaulting to the workspace root when no path is given.

#### Scenario: Default listing
- **WHEN** `list` is called with no path
- **THEN** entries of the workspace root are returned, sorted, with
  `count`

### Requirement: Glob semantics
`glob` SHALL enumerate files under the base directory (`find
-type f`), match the pattern against the relative path OR the
basename, and support `*` (no slash), `**` (any depth), `?`,
`[abc]`, `[!abc]`. Results SHALL be sorted and capped at 500 files.

#### Scenario: 500-file cap
- **WHEN** a pattern matches 800 files
- **THEN** exactly 500 are returned, sorted

#### Scenario: Double-star crosses directories
- **WHEN** the pattern is `**/main.lua`
- **THEN** matches at any depth are included

### Requirement: Grep fallback chain
`grep` SHALL prefer `rg -n --no-heading`, fall back to `grep -rn`
when the first yields nothing, support `ignore_case`, an optional
`glob` filter flag, and a `max_results` default of 100. Match
records SHALL carry `{path (workspace-relative), line, column,
text}`; column is 1 when the tool omits it.

#### Scenario: rg present and empty
- **WHEN** `rg` exits with no output but `grep -R` has matches
- **THEN** the grep results are returned

### Requirement: Atomic write
`write` SHALL create the file through a uniquely-named temp file in
the same directory and rename it into place, returning `{bytes,
path}` with path workspace-relative.

#### Scenario: Write success
- **WHEN** the content is 42 bytes
- **THEN** the result is `{bytes=42, path=<rel>}` and the temp
  file no longer exists

### Requirement: Strict patch application
`patch` SHALL parse unified-diff files, take the `b/` path when
present, apply hunks from last to first, and require every old-line
to match exactly at its declared position. On any mismatch it SHALL
fail with `patch conflict in <file> — перечитайте файл` and leave
the file untouched. Results SHALL report `{files, add, del,
applied[]}`.

#### Scenario: Conflict leaves file intact
- **WHEN** a hunk's context lines no longer match
- **THEN** the tool returns the conflict error and the target file
  is not modified

### Requirement: Shell execution
`run` SHALL execute via `/bin/sh -c` in a subshell of
`cd <cwd> && timeout <s> env TETHER_WORKSPACE=<cwd> sh -c <cmd>`,
defaulting timeout to `cfg.tools.run_shell.timeout` (120 s) and cwd
to the workspace root. Output (stdout+stderr) SHALL be captured to a
unique temp file and removed afterwards; the result carries
`{output, exit_code, elapsed_ms}`.

#### Scenario: Timeout kills the command
- **WHEN** the command runs past the timeout
- **THEN** exit_code is 124 and elapsed_ms reflects the limit

#### Scenario: Env visibility
- **WHEN** the command echoes `$TETHER_WORKSPACE`
- **THEN** the output contains the resolved workspace path

### Requirement: Outside-workspace guard
`write` and `run` SHALL reject targets resolving outside the
workspace with the error `... outside workspace requires
confirmation` (the agent layer then asks the user); `allow_outside_workspace =
true` bypasses the guard entirely.

#### Scenario: allow_outside_workspace true
- **WHEN** the flag is set and write targets `/etc/hosts`
- **THEN** the tool executes without an error result

> drift: design.md §7 says "выход за корень требует
> подтверждения" — in code the tool returns a refusal and the agent's
> confirmation menu is what grants the one-off session/always
> exception; the flag bypass is the only permanent route.
