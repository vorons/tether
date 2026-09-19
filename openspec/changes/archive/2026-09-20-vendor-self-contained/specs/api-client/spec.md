# Spec Delta

## MODIFIED Requirements

### Requirement: SSE streaming request
The client SHALL select a provider adapter by `cfg.provider` (`openai` | `anthropic` | `gemini`, default `openai`) and POST the provider-specific streaming request: OpenAI-compatible `{"model":..., "messages":..., "stream":true}` JSON to `<base_url>/chat/completions`; Anthropic `{"model":..., "messages":..., "stream":true, "tools":..., "max_tokens":...}` JSON to `<base_url>/v1/messages`; Gemini `{"contents":..., "tools":...}` JSON to `<base_url>/v1beta/models/<model>:streamGenerateContent` (SSE) with REST `generateContent` fallback. The request SHALL be issued by the in-process HTTP client (vendored libcurl + mbedTLS): the body is written to a temp file and handed to the client as a file handle, so it never appears in a process argv and no `curl` subprocess is spawned. An empty line in the stream is an event boundary, not EOF; parsing SHALL continue after it. Unknown `cfg.provider` values SHALL fall back to `openai` with a stderr warning.

#### Scenario: Multi-event stream
- **WHEN** the stream contains two `data:` events separated by an
  empty line
- **THEN** both events are parsed and their deltas forwarded

#### Scenario: Unknown provider falls back
- **WHEN** `cfg.provider` is `"azure"` (unknown)
- **THEN** the OpenAI-compatible adapter is used and a stderr warning names the unknown value

#### Scenario: In-process transport
- **WHEN** the agent calls `api.stream(cfg, key, messages, on_event)`
- **THEN** the request is issued through the in-process HTTP client (no `curl` process) and SSE events reach `on_event` in stream order

### Requirement: API key never in argv
The client SHALL write the `Authorization` header (or the provider's equivalent auth header) to a private temp file (mode 600) and pass that file handle to the in-process HTTP client; the key SHALL not appear in the process argv or in the environment. The temp file SHALL be created with mode 600 before the key is written, so there is no window in which the key is readable by other users; if the mode cannot be applied the client SHALL fail before issuing the request. The header file and request body file SHALL be removed after the request, on both success and failure.

#### Scenario: Key not visible in ps
- **WHEN** a request is in flight
- **THEN** `ps` shows no key text — the key travels only through the mode-600 temp header file, and no `curl` command is spawned

#### Scenario: Key file permissions
- **WHEN** the client prepares a request with an API key
- **THEN** the header temp file exists with mode 600 before the key is written into it
