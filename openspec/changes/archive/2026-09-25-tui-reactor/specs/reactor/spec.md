# Spec Delta

## Purpose

The reactor is the single-threaded event loop that owns waiting: one poll over standard input, transport sockets and timers drives keys, streaming, spinner, backoff and resize, so the TUI stays live for the whole turn with no blocking transfer call.

## ADDED Requirements

### Requirement: One loop owns waiting

The reactor SHALL be the only owner of waiting in the interactive session:
one iteration SHALL poll standard input, the active transport's sockets and
the nearest timer deadline together, then dispatch whatever is ready. No
transfer, sleep or tool wait on the reactor path SHALL block the OS thread
past one tick quantum (80 ms). `tether.http_stream` keeps its blocking
contract for print mode and one-shot callers off the reactor path.

#### Scenario: Keys handled mid-transfer
- **WHEN** a wheel tick arrives while a response streams with no deltas in flight
- **THEN** the tick is decoded and applied within one tick quantum, without waiting for the next model or tool event

#### Scenario: Single quantum bound
- **WHEN** nothing is ready on any descriptor
- **THEN** one reactor iteration lasts no longer than one tick quantum plus dispatch

### Requirement: Input is always live

Every key, mouse and resize event SHALL be decoded and dispatched on the
reactor tick it arrives on, whether a turn is running or not. Scroll, steering
submit and abort SHALL take effect within one tick of arrival. An escape
sequence split across reads SHALL NEVER surface as text: an incomplete
sequence SHALL be buffered and retried whole on the next tick, and only a
complete sequence SHALL be dispatched.

#### Scenario: Scroll applies mid-turn
- **WHEN** the user scrolls while the turn waits silently for the first token
- **THEN** the viewport moves and repaints within one tick quantum

#### Scenario: Fragmented sequence never leaks
- **WHEN** an SGR mouse sequence arrives split across two ticks
- **THEN** the input line stays unchanged and the completed sequence dispatches as one mouse event

### Requirement: Timer and deadline semantics

The reactor SHALL fire timer callbacks no later than one tick quantum after
their deadline. The spinner SHALL advance on reactor ticks while a turn runs.
A backoff wait SHALL end early when input arrives (existing abort semantics
apply) and SHALL otherwise last its requested duration. Closed stdin SHALL
NOT be reported as input and SHALL NOT spin the loop.

#### Scenario: Spinner advances in silence
- **WHEN** a turn waits with no stream events
- **THEN** the spinner frame still advances on tick cadence

#### Scenario: Backoff wakes on input
- **WHEN** the user scrolls during a retry backoff
- **THEN** the scroll applies and the wait ends early per the abort contract

### Requirement: Deterministic test surface

The reactor SHALL expose its tick so tests can drive scripted descriptor
readiness without wall-clock waits: fed bytes, socket lines and expired
deadlines SHALL dispatch in readiness order, and two runs over the same
script SHALL produce the same dispatch order.

#### Scenario: Scripted run is repeatable
- **WHEN** a test feeds the same byte and line script twice
- **THEN** both runs dispatch the same event sequence
