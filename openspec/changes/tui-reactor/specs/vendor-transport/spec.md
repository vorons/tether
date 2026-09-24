# Spec Delta

## ADDED Requirements

### Requirement: Incremental transfer

The transport SHALL offer every `http_stream` transfer incrementally with
identical wire behavior: start SHALL open the request and return a handle;
each step SHALL move the transfer forward within its timeout; drained lines
SHALL arrive in the same order and framing as `http_stream` delivers
(including `""` SSE boundaries and a trailing line without newline);
abort SHALL end the transfer as a failure; freeing the handle SHALL release
the transfer. TLS trust, credential-file handling and timeout defaults
SHALL match `http_stream` exactly.

#### Scenario: Stepped body equals streamed body
- **WHEN** the same response is consumed via steps and via `http_stream`
- **THEN** both deliver the same line sequence

#### Scenario: Abort is a failure
- **WHEN** the reactor aborts a stepped transfer
- **THEN** the attempt reports a failure, never a partial success
