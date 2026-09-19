# Spec Delta

## Purpose

In-process HTTP/HTTPS client for LLM provider APIs, replacing the shell-piped curl transport. The client is built on vendor'd static libraries (libcurl, mbedTLS, zlib) and exposes a Lua-friendly API that the existing `api.lua` event protocol can consume unchanged.

## ADDED Requirements

### Requirement: HTTP stream
The client SHALL provide `tether.http_stream(method, url, headers, body, on_line, opts)` that performs an HTTP(S) request in process (vendor'd libcurl + mbedTLS) and invokes the Lua callback `on_line(line)` once per body line. `method` is an HTTP verb (`POST` is the default framing). `headers` is an array of `"Name: value"` strings, where an entry `"@<path>"` stands for the contents of that file; `body` is a string or `"@<path>"`. Because credentials and payload travel as files handed to the client, the key never enters the process argv or the environment. `opts` is optional: `timeout_s` / `connect_timeout_s` set the connect timeout (default 10 s) and `idle_timeout_s` sets the maximum gap between bytes of body data before the transfer is aborted (default 60 s). A successful transfer SHALL return `true`; a failure SHALL return `nil, error_string`. An empty line in the body SHALL be delivered as `""` (an SSE event boundary, not EOF), and a trailing line without a newline SHALL still be delivered.

#### Scenario: streaming SSE from OpenAI
- **WHEN** the agent calls `tether.http_stream("POST", "https://api.openai.com/v1/chat/completions", { "@" .. header_file }, "@" .. body_file, on_line, { timeout_s = 10 })`
- **THEN** `on_line` receives each SSE `data:` line until the stream closes, the call returns `true`, and the key exists only inside the mode-600 header file

#### Scenario: blank SSE separator
- **WHEN** the body contains two `data:` events separated by an empty line
- **THEN** `on_line` is called with the separator as `""` and both events are delivered

#### Scenario: transport failure
- **WHEN** the request cannot be completed (connect, TLS or transfer error)
- **THEN** the call returns `nil, err` and `api.lua` surfaces it as an `error` event once its retry policy is exhausted

### Requirement: HTTP get
The client SHALL provide `tether.http_get(url, headers, timeout_s)` that performs a GET request and returns the full response body as a string, or `nil, error_string` on failure. `headers` uses the same array form as `http_stream` (including `"@<path>"`). `timeout_s` is the total request timeout in seconds, default 30 when omitted. HTTP error status codes (>= 400) SHALL be reported as `nil, "http <status>"` rather than as a body.

#### Scenario: list models via GET
- **WHEN** the agent calls `tether.http_get("https://api.openai.com/v1/models", { "@" .. header_file }, 30)`
- **THEN** the call returns the JSON body; on HTTP 401 the call returns `nil, "http 401"`

### Requirement: TLS trust store
The client SHALL verify TLS against the system CA bundle (`/etc/ssl/certs/ca-certificates.crt` or the distribution equivalent). No `CURL_CA_BUNDLE` and no per-call override SHALL be accepted: the trust anchor is the OS-distributed bundle. When no bundle is found the call SHALL fail with `nil, "no system CA bundle found"` before opening a connection. A peer certificate that does not chain to the bundle SHALL fail the transfer with a non-nil error and no body.

#### Scenario: TLS verification failure
- **WHEN** the server presents a self-signed certificate that the system CA bundle does not chain
- **THEN** the call returns `nil, err` with no body delivered, and `api.stream` surfaces it as an `error` event
