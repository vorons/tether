# Spec Delta

## ADDED Requirements

### Requirement: Non-blocking transport step primitives

The host SHALL expose the active transfer as an incremental handle the
reactor can drive: start a request, report the sockets to poll, step with a
bounded timeout, drain received lines, abort on `0x03`, and free the handle.
A step SHALL NEVER block past its timeout and SHALL NEVER read standard
input itself; stdin readiness is reported through the poll set so the
reactor — never a transfer callback — owns key dispatch.

#### Scenario: Transfer progresses in steps
- **WHEN** the reactor steps a started transfer with ready sockets
- **THEN** received lines are drained to the caller and the transfer continues

#### Scenario: Abort sets the interrupt flag
- **WHEN** `0x03` arrives while a stepped transfer is in flight
- **THEN** the transfer aborts and `tether.abort_requested()` reports true until cleared

#### Scenario: Step never blocks on input
- **WHEN** a step runs with no socket or input readiness
- **THEN** it returns at its timeout having consumed no stdin byte

## MODIFIED Requirements

### Requirement: Character input API

`tether.read_char()` SHALL read one byte of input, blocking, and SHALL
return `nil` on EOF; `tether.read_char_nb()` SHALL return immediately
without waiting — `nil` when no byte is available or on EOF, and the byte
value otherwise. It SHALL NOT perform a bounded wait: readiness waiting
belongs to the reactor's poll, so no transfer or timer callback can stall
on input. The interactive loop SHALL treat `nil` as end of input and
terminate cleanly with exit code 0.

#### Scenario: EOF pipe
- **WHEN** stdin is a pipe that closes
- **THEN** read_char returns nil (`0` in Lua truthiness terms) and the process exits 0

#### Scenario: Non-blocking drain never waits
- **WHEN** `tether.read_char_nb()` runs with no byte available
- **THEN** it returns nil without delaying the caller
