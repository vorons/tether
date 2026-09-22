# Spec Delta

## ADDED Requirements

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
