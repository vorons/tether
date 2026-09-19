# Spec Delta

## Purpose

In-process file- and text-search primitives that replace all remaining external CLI tool dependencies (`ls`, `find`, `rg`, `grep`, `chmod`, `mkdir -p`). The capability provides C-level syscalls wrapped as `tether.*` Lua functions, plus a vendor'd krep engine (pure C, POSIX `regex.h` + `fnmatch.h`) for regex search with gitignore support.

## ADDED Requirements

### Requirement: filesystem primitives
The host SHALL expose `tether.mkdirp(path)`, `tether.fchmod(path, mode)`, `tether.readdir(path)`, and `tether.stat(path)`. These primitives SHALL be the only mechanism by which the application creates directories, changes file permissions, lists directory contents, or reads file metadata.

#### Scenario: create nested directory tree
- **WHEN** the application calls `tether.mkdirp("/home/user/.tether/sessions")`
- **THEN** all intermediate directories are created; the call returns `true`

#### Scenario: list directory entries
- **WHEN** the application calls `tether.readdir("/some/dir")`
- **THEN** the call returns a table of entry names sorted alphabetically, excluding `.` and `..`

#### Scenario: stat a file
- **WHEN** the application calls `tether.stat("/some/file.jsonl")`
- **THEN** the call returns `{mtime = <unix seconds>, size = <bytes>, is_dir = false}`

### Requirement: krep search engine
The application SHALL use the vendor'd krep engine for all `grep` tool invocations. The engine SHALL:
- honor `.gitignore` and `.ignore` files in the walked directory tree
- accept an optional `glob` filter string (krep's `--glob` syntax)
- accept an `ignore_case` flag
- support POSIX extended regular expressions (`-E`); PCRE-only constructs are not supported
- return matches as `{path, line, column, text}` records, capped at `max_results`

No external `rg`, `grep`, `find`, or `ls` binary SHALL be required at runtime.

#### Scenario: grep with gitignore
- **WHEN** the user invokes `grep` with pattern `foo` in a directory that has a `.gitignore` containing `*.log`
- **THEN** no `.log` file appears in the results

#### Scenario: grep with glob filter
- **WHEN** the user invokes `grep` with pattern `bar` and `glob = "*.py"`
- **THEN** only `.py` files are searched

### Requirement: glob enumeration
The `glob` tool SHALL enumerate files by recursive in-process directory walk (`tether.readdir` + `tether.stat`), not via `find`. The pattern matching semantics (`*`, `**`, `?`, `[abc]`, `[!abc]`) SHALL remain as currently defined.

#### Scenario: glob enumerates files
- **WHEN** the user invokes `glob` with pattern `*.lua` in the workspace
- **THEN** all matching `.lua` files are returned as workspace-relative paths, sorted, capped at 500
