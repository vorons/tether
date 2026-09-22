
# host

## Purpose

The C host: single-binary embedding of the Lua sources, raw-mode
terminal I/O, signal handling, and the `tether.*` Lua API surface the
application layers call.


## Requirements

### Requirement: Single binary
The build SHALL embed all `src/tether/*.lua` sources into the
binary (generated `embed.c` byte arrays, one per module, C names
`app_lua`, `ui_lua`, ...). `make` SHALL produce `./tether` with no
external Lua runtime dependency; `embed.c` is regenerated when any
Lua source or `tools/embed.lua` changes.

#### Scenario: Rebuild after Lua edit
- **WHEN** a .lua module is edited and `make` runs
- **THEN** `embed.c` is regenerated and linked

#### Scenario: No lua on PATH
- **WHEN** the binary runs on a system without a lua interpreter
- **THEN** it still runs the embedded sources

### Requirement: Raw mode setup and restore

On start the host SHALL save termios, enable raw mode, and hide the
cursor; on any exit path (SIGTERM, normal exit and crash unwind) it
SHALL restore termios and re-show the cursor (`\x1b[?25h`). Raw mode
SHALL disable `ISIG`, so `Ctrl+C` is delivered to the application as
the byte `0x03` rather than a signal and the terminal stays usable; a
SIGINT delivered externally SHALL also restore the terminal before the
process exits.

#### Scenario: SIGTERM restores the terminal
- **WHEN** the process receives SIGTERM mid-run
- **THEN** the previous termios is restored and the cursor is
  visible in the calling shell

#### Scenario: Ctrl+C is delivered as a byte
- **WHEN** the user presses `Ctrl+C` in the raw-mode TUI
- **THEN** the application reads byte `0x03` and no SIGINT is raised

#### Scenario: External SIGINT restores the terminal
- **WHEN** the process receives SIGINT from outside the terminal
- **THEN** termios is restored and the cursor is re-shown before exit

### Requirement: Resize signal
SIGWINCH SHALL set a flag (SA_RESTART) the Lua loop polls via
`tether.resize_requested()`, without disturbing I/O; the TUI SHALL
re-layout on the next redraw.

#### Scenario: Window resized mid-stream
- **WHEN** SIGWINCH arrives while a stream is rendering
- **THEN** the next frame is drawn at the new size

### Requirement: Character input API

`tether.read_char()` SHALL read one byte of input, blocking, and SHALL
return `nil` on EOF; `tether.read_char_nb()` SHALL return without
blocking (a short bounded poll), `nil` when no byte is available or on
EOF, and the byte value otherwise. The interactive loop SHALL treat
`nil` as end of input and terminate cleanly with exit code 0.

#### Scenario: EOF pipe
- **WHEN** stdin is a pipe that closes
- **THEN** read_char returns nil (`0` in Lua truthiness terms) and the process exits 0

### Requirement: Interrupt while the host blocks a turn
Raw mode delivers an in-terminal Ctrl+C as byte 0x03 rather than SIGINT, and
the UI reads its input only between turns — so while a turn blocks, nobody
reads that byte and the keystroke sits unread until the turn it was meant to
interrupt has finished. The host SHALL therefore watch standard input itself
while it blocks a turn, both while waiting (`tether.sleep`) and while an HTTP
transfer is in flight:

- `tether.sleep` SHALL return as soon as input arrives, and SHALL still take no
  longer than the requested duration when nothing arrives.
- An in-flight HTTP transfer SHALL be aborted when 0x03 arrives, so a stalled
  stream cannot hold the turn.
- 0x03 SHALL set an interrupt flag instead of being delivered as input.
  `tether.abort_requested()` SHALL report that flag, and `tether.clear_abort()`
  SHALL clear it. The flag SHALL stay set until it is cleared, so the same
  Ctrl+C keeps aborting an in-flight transfer until the turn has actually
  stopped; the turn clears it once it has handled the abort.
- Every other byte read while watching SHALL be kept and later returned by
  `tether.read_char` / `tether.read_char_nb`, in the order it was typed, so
  watching input never loses a keystroke.
- The watch SHALL be non-blocking: it SHALL NOT consume a byte that is not
  already available, and SHALL NOT delay a transfer or a wait.

End of input SHALL stop the watch: a closed or exhausted stdin SHALL not be
reported as an interrupt, and a wait with a closed stdin SHALL still last its
requested duration instead of returning immediately in a spin.

#### Scenario: A wait wakes on the interrupt
- **WHEN** the user presses Ctrl+C while the agent waits 60 seconds between attempts
- **THEN** the wait returns immediately and `tether.abort_requested()` reports true

#### Scenario: The interrupt stays set until the turn clears it
- **WHEN** `tether.abort_requested()` has reported true and the turn has not cleared it
- **THEN** a second call still reports true, so the transfer being aborted cannot be mistaken for one that finished

#### Scenario: The interrupt is cleared once
- **WHEN** the turn clears the interrupt with `tether.clear_abort()`
- **THEN** `tether.abort_requested()` reports false, so one Ctrl+C aborts one turn

#### Scenario: Clearing without reporting
- **WHEN** `tether.clear_abort()` runs
- **THEN** a following `tether.abort_requested()` reports false

#### Scenario: A stalled transfer is aborted
- **WHEN** Ctrl+C arrives while an HTTP transfer is in flight and has sent no data
- **THEN** the transfer ends instead of waiting out its timeouts, and `tether.abort_requested()` reports true

#### Scenario: Typed keys survive the watch
- **WHEN** the user types `abc` while a turn is blocked
- **THEN** subsequent `tether.read_char` calls return `a`, then `b`, then `c`

#### Scenario: A quiet wait still lasts its duration
- **WHEN** `tether.sleep(0.2)` runs with nothing available on stdin
- **THEN** it returns after about 0.2 seconds

#### Scenario: Closed stdin is not an interrupt
- **WHEN** stdin is at end of input and `tether.sleep` runs
- **THEN** the wait lasts its requested duration, no interrupt is reported, and the host does not spin

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

### Requirement: Shell execution API
`tether.exec(cmd)` SHALL run a command through `/bin/sh -c` and return `(ok, exit_code)`, where `ok` is true only when the exit code is 0. It SHALL be the host's only shell-execution primitive, and `tools.run` SHALL be its only caller.

#### Scenario: run executes through tether.exec
- **WHEN** the user invokes the `run` tool with `echo hi`
- **THEN** the command reaches `tether.exec` wrapped as `/bin/sh -c` under `timeout`, and the tool returns `{output, exit_code, elapsed_ms}` with `hi` in the output

#### Scenario: exit code is propagated
- **WHEN** the `run` tool executes a command that exits with status 3
- **THEN** the tool result carries `exit_code == 3`

### Requirement: Embed tool contract

`tools/embed.lua <out.c> <name> <path> ...` SHALL write a C file of
`unsigned char` arrays (12 bytes per line, 0x00 terminated) plus
string aliases; the Makefile SHALL pass every Lua module of the core —
`app`, `ui`, `config`, `session`, `api`, `context`, `agent`, `tools`,
the `providers/*` modules and the shared helpers — and the list SHALL
grow with the core rather than being a fixed count.

#### Scenario: Generated file header
- **WHEN** embed.lua runs
- **THEN** the output starts with the "generated — do not edit"
  marker

#### Scenario: Provider and context modules are embedded
- **WHEN** `make` builds the binary
- **THEN** `embed.c` contains arrays for `context`, `provider_common`, `provider_openai`, `provider_anthropic` and `provider_gemini` alongside the core modules

> drift: none observed against design.md §8 (terminal I/O) — the
> documented behaviors match the C layer.
