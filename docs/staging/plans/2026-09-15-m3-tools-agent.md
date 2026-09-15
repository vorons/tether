# tether M3 — plan

spec: docs/staging/specs/2026-09-15-m3-tools-agent.md
date: 2026-09-15

## Goal
Complete M3: agent dispatches read/list/glob/grep tools via LLM tool_call parsing, and API uses curl SSE streaming.

## Context
- `tools.lua` implements read/list/glob/grep (exists)
- `agent.lua` has system prompt listing tools but does not dispatch them
- `api.lua` uses blocking curl (`stream: false`) instead of SSE streaming
- C host has pipe APIs (`open_pipe`, `read_line`, `close_pipe`, `pipe_eof`) ready for SSE

## Tasks

- [ ] T1: Rewrite `api.lua` for SSE streaming via `tether.open_pipe`/`tether.read_line`
  - Use `curl -s -N` with `stream: true`
  - Parse SSE lines (`data: ...`) into canonical events
  - Emit `text_delta`, `tool_call_start`, `tool_call_delta`, `tool_call_end`, `usage`, `done`, `error`
  - Acceptance: `lua -e "local api = require('api'); ..."` parses sample SSE output

- [ ] T2: Add tool-call parsing to `agent.lua`
  - Parse `tool_calls` from LLM response JSON
  - Execute tools via `tools.*` module
  - Feed results back as `tool_result` messages
  - Loop until no more tool calls
  - Acceptance: agent dispatches read tool and returns file content

- [ ] T3: Wire tools into `ui.lua` transcript rendering
  - Show `⚙ <name>` for tool success, `✗ <name>` for errors
  - Display summaries for hidden results
  - Acceptance: `tether` binary runs without errors, shows tool calls in transcript

- [ ] T4: `make test` passes with new M3 code
  - Acceptance: `make test` → `PASS: all M2 smoke checks`
