# Spec Delta

## MODIFIED Requirements

### Requirement: Path and terminal API
The host SHALL expose `tether.realpath`, `tether.getcwd`, `tether.get_terminal_size` (rows, cols via ioctl), `tether.is_tty()` (is-interactive), `tether.write`, and the file-system primitives `tether.mkdirp`, `tether.fchmod`, `tether.readdir` and `tether.stat`. `tether.readdir` SHALL return entry names with `.`/`..` removed; `tether.stat` SHALL report `{mtime, size, is_dir}` with lstat semantics.

#### Scenario: Non-tty detection
- **WHEN** stdout is piped
- **THEN** `tether.is_tty()` is false and TUI init is skipped in
  print mode

#### Scenario: tether.mkdirp creates nested directories
- **WHEN** the application calls `tether.mkdirp("/a/b/c")` where `/a/b` does not exist
- **THEN** all intermediate directories are created and the call returns `true`

#### Scenario: tether.readdir lists a directory
- **WHEN** the application calls `tether.readdir("/some/dir")`
- **THEN** the call returns a table of entry names (no `.` or `..`)

#### Scenario: tether.stat returns file metadata
- **WHEN** the application calls `tether.stat("/some/file")`
- **THEN** the call returns `{mtime = <unix seconds>, size = <bytes>, is_dir = <bool>}`

## REMOVED Requirements

### Requirement: Process and pipe API
**Reason**: The `open_pipe` / `read_line` / `close_pipe` / `pipe_eof` family has no caller left. Its only consumer was the piped `curl` transport, which is now in-process, and `tools.run` — previously assumed to be the consumer — executes through `tether.exec`. Keeping a fork/pipe layer that nothing calls contradicts this change's self-contained goal and leaves the host spec describing a mechanism the binary no longer needs, so the four primitives, the global pipe state and their registry entries are deleted.
**Migration**: Shell execution is `tether.exec(cmd)` (`/bin/sh -c`, returns `(ok, exit_code)`). Streaming bodies arrive through `tether.http_stream(..., on_line, opts)`; listing, search and metadata use `tether.readdir` / `tether.stat` / `tether.krep_search`. An empty line in a stream is still delivered as `""` — that guarantee now lives in `tether.http_stream` and in the `vendor-transport` capability.

## ADDED Requirements

### Requirement: Shell execution API
`tether.exec(cmd)` SHALL run a command through `/bin/sh -c` and return `(ok, exit_code)`, where `ok` is true only when the exit code is 0. It SHALL be the host's only shell-execution primitive, and `tools.run` SHALL be its only caller.

#### Scenario: run executes through tether.exec
- **WHEN** the user invokes the `run` tool with `echo hi`
- **THEN** the command reaches `tether.exec` wrapped as `/bin/sh -c` under `timeout`, and the tool returns `{output, exit_code, elapsed_ms}` with `hi` in the output

#### Scenario: exit code is propagated
- **WHEN** the `run` tool executes a command that exits with status 3
- **THEN** the tool result carries `exit_code == 3`
