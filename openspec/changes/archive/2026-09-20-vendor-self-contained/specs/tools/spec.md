# Spec Delta

## MODIFIED Requirements

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
