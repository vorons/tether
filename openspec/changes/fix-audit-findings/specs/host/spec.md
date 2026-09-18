# Spec Delta: host

## MODIFIED Requirements

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

### Requirement: Character input API

`tether.read_char()` SHALL read one byte of input, blocking, and SHALL
return `nil` on EOF; `tether.read_char_nb()` SHALL return without
blocking (a short bounded poll), `nil` when no byte is available or on
EOF, and the byte value otherwise. The interactive loop SHALL treat
`nil` as end of input and terminate cleanly with exit code 0.

#### Scenario: EOF pipe
- **WHEN** stdin is a pipe that closes
- **THEN** read_char returns nil (`0` in Lua truthiness terms) and the process exits 0

### Requirement: Path and terminal API

The host SHALL expose `tether.realpath`, `tether.getcwd`,
`tether.get_terminal_size` (rows, cols via ioctl), `tether.is_tty()`
(is-interactive), and `tether.write`.

#### Scenario: Non-tty detection
- **WHEN** stdout is piped
- **THEN** `tether.is_tty()` is false and TUI init is skipped in
  print mode

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
