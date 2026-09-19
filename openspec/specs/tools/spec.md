
# tools

## Purpose

File and shell tool execution: read/list/glob/grep/write/patch/run
with a strict workspace path policy.


## Requirements

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
`list` SHALL return the sorted entries of a directory through the
in-process `tether.readdir` primitive, defaulting to the workspace root
when no path is given. No `ls` process SHALL be spawned.

#### Scenario: Default listing
- **WHEN** `list` is called with no path
- **THEN** entries of the workspace root are returned, sorted, with
  `count`

#### Scenario: List a sub-directory
- **WHEN** the user invokes `list` with `path = "src/tether"`
- **THEN** the tool returns the sorted entries of that sub-directory

### Requirement: Glob semantics
`glob` SHALL enumerate files under the base directory with a recursive
in-process walk (`tether.readdir` + `tether.stat`, so lstat semantics
and no symlink following — no `find` process), match the pattern
against the relative path OR the basename, and support `*` (no slash),
`**` (any depth), `?`, `[abc]`, `[!abc]`. Results SHALL be sorted and
capped at 500 files.

#### Scenario: 500-file cap
- **WHEN** a pattern matches 800 files
- **THEN** exactly 500 are returned, sorted

#### Scenario: Double-star crosses directories
- **WHEN** the pattern is `**/main.lua`
- **THEN** matches at any depth are included

#### Scenario: Glob matches files
- **WHEN** the user invokes `glob` with pattern `*.lua`
- **THEN** the tool returns all `.lua` files in the workspace
  (relative paths, sorted, max 500)

### Requirement: Grep engine
`grep` SHALL search through the vendored krep engine in process — no
`rg` or `grep` process, and no shell pipeline. It SHALL honor
`.gitignore` by default and support `ignore_case`, an optional `glob`
filter and a `max_results` default of 100. Patterns are POSIX extended
regular expressions; PCRE-only constructs (lookaround) are not
supported. Match records SHALL carry `{path (workspace-relative),
line, column, text}`; `column` is always 1 because krep's printed
record carries no column.

krep applies its own skip lists, so these are never searched:
directories `build`, `bin`, `obj`, `dist`, `target`, `.git`,
`node_modules`, `venv`; extensions `.log`, `.dat`, `.bin`, `.tmp`,
`.o`, `.a`, plus archives, images, audio/video and fonts. This is a
documented coverage difference from a plain `rg`/`grep` invocation, not
a defect.

#### Scenario: Grep returns matches
- **WHEN** `grep` is called with pattern `function`
- **THEN** up to 100 records shaped `{path, line, column, text}` are
  returned, with `column` always 1

#### Scenario: Gitignored path excluded
- **WHEN** a path is listed in `.gitignore`
- **THEN** that path does not appear in the results

#### Scenario: Glob filter
- **WHEN** `grep` is called with `glob = "*.py"`
- **THEN** only `.py` files are searched

#### Scenario: Directory on krep's skip list
- **WHEN** the only match lives under `build/`
- **THEN** it is not returned

### Requirement: Atomic write
`write` SHALL create the file through a uniquely-named temp file in
the same directory and rename it into place, returning `{bytes,
path}` with path workspace-relative.

#### Scenario: Write success
- **WHEN** the content is 42 bytes
- **THEN** the result is `{bytes=42, path=<rel>}` and the temp
  file no longer exists

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

> design.md §7 describes the same flow: the tool refuses on its own
> (`... outside workspace requires confirmation`), the agent's
> confirmation menu grants the one-off/session/always exception, and
> `allow_outside_workspace = true` is the only permanent bypass.
