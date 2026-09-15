# tether M4 — plan

spec: docs/staging/specs/2026-09-15-m4-write-patch-run.md
date: 2026-09-15

## Goal
Add write/patch/run tools, confirmation menus, diff overlay, and config updates.

## Milestone
M4: write / patch / run + confirmation menus

## Context
- `tools.lua` has read/list/glob/grep (M3)
- `agent.lua` has tool dispatch loop (M3)
- `ui.lua` has basic TUI rendering
- `api.lua` has SSE streaming
- `config.lua` exists (simple load)
- C host has `tether.exec`, `open_pipe`, `read_line`, etc.

## Tasks

### T1: Add `write`, `patch`, `run` tools to `tools.lua` [DONE]
- `write(path, content)`: create/overwrite file; check workspace boundary; return bytes written
- `patch(patch_str)`: apply unified diff strictly; return +N/-M summary
- `run(command, cwd?, timeout?)`: `/bin/sh -c`; cwd inside workspace; 120s default timeout
- `M._workspace` getter for boundary checks
- Acceptance: each tool returns structured result; out-of-workspace returns error

### T2: Add config fields and `config.lua` update [DONE]
- `auto_approve = {}` table
- `allow_outside_workspace = false`
- `ui.thinking`, `ui.collapse`, `ui.wrap`, `ui.input_max_lines`
- `context.max_tokens`, `context.summarize_at`
- `tools.run_shell.timeout`
- Acceptance: `config.load()` returns full config with defaults

### T3: Add confirmation logic to `agent.lua` [DONE]
- `should_confirm(tool_name, args, cfg)`: true for write/patch/run outside workspace
- `check_auto_approve(tool_name, args, cfg)`: check `auto_approve` list
- On confirmation needed: emit `confirmation` event with tool details
- Agent pauses until confirmation result arrives
- Acceptance: agent correctly identifies tools needing confirmation

### T4: Update `ui.lua` for tool blocks, confirmation menu, diff overlay [DONE]
- `⚙ <name>` for auto-approved tools, `⚠ <name>` for confirmation-required
- Diff overlay rendering (unified diff, `┌│└` borders)
- Confirmation menu overlay with `[y] once [a] session [A] always [d] details [n] deny [Esc] cancel`
- `Ctrl+O` expand/collapse, `Ctrl+T` toggle thinking
- Status line and hint line
- Acceptance: `tether` binary runs; confirmation menu appears for write/patch/run

### T5: Update `api.lua` for `run` tool streaming [DONE]
- `run` tool uses curl subprocess via `tether.exec`
- Acceptance: run tool works with streaming

### T6: `make test` passes [DONE]`

## Dependencies
- T1 (tools) and T2 (config) are independent
- T3 (confirmation) depends on T1 and T2
- T4 (UI) depends on T1, T2, T3
- T5 depends on T1
- T6 is final
