
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
cursor; on any exit path (SIGTERM, EOF, crash unwind) it SHALL
restore termios and re-show the cursor (`\x1b[?25h`). SIGINT SHALL
leave the terminal usable.

#### Scenario: SIGTERM restores the terminal
- **WHEN** the process receives SIGTERM mid-run
- **THEN** the previous termios is restored and the cursor is
  visible in the calling shell

### Requirement: Resize signal
SIGWINCH SHALL set a flag (SA_RESTART) the Lua loop polls via
`tether.resize_requested()`, without disturbing I/O; the TUI SHALL
re-layout on the next redraw.

#### Scenario: Window resized mid-stream
- **WHEN** SIGWINCH arrives while a stream is rendering
- **THEN** the next frame is drawn at the new size

### Requirement: Character input API
`tether.read_char()` SHALL read one byte of input, blocking;
`tether.read_char_nb()` SHALL return immediately, 0 on EOF, and
surface the byte or a special value on a key. On EOF the interactive
loop SHALL terminate cleanly with exit code 0.

#### Scenario: EOF pipe
- **WHEN** stdin is a pipe that closes
- **THEN** read_char returns 0 and the process exits 0

### Requirement: Process and pipe API
`tether.exec(cmd)` SHALL run a command, capturing its exit code.
`tether.open_pipe(cmd)` SHALL start a command returning a handle;
`tether.read_line(handle)` SHALL return one line (an empty line
returns `""`, not nil — nil means EOF); `tether.close_pipe()` SHALL
reap the child; `tether.pipe_eof()` SHALL report stream end.

#### Scenario: Empty SSE separator line
- **WHEN** the child writes `\n\n`
- **THEN** read_line returns `""` for the empty line and parsing
  continues (nil only at real EOF)

### Requirement: Path and terminal API
The host SHALL expose `tether.realpath`, `tether.getcwd`,
`tether.get_terminal_size` (rows, cols via ioctl), `tether.tty()`
(is-interactive), and `tether.write`.

#### Scenario: Non-tty detection
- **WHEN** stdout is piped
- **THEN** `tether.tty()` is false and TUI init is skipped in
  print mode

### Requirement: Embed tool contract
`tools/embed.lua <out.c> <name> <path> ...` SHALL write a C file of
`unsigned char` arrays (12 bytes per line, 0x00 terminated) plus
string aliases; the Makefile passes exactly the seven application
modules.

#### Scenario: Generated file header
- **WHEN** embed.lua runs
- **THEN** the output starts with the "generated — do not edit"
  marker

> drift: none observed against design.md §8 (terminal I/O) — the
> documented behaviors match the C layer.
