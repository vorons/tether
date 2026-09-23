# Tasks

## 1. Decoder and queue state

- [x] 1.1 Preserve alt on modified Enter (distinct event or alt flag on newline); unit-test kitty CSI-u and modifyOtherKeys Alt+Enter vs Shift+Enter vs plain Enter
- [x] 1.2 Add `S.steer_queue` / `S.followup_queue` (max 8 each) and a pure enqueue helper with cap → error banner; unit-test cap and order

## 2. Busy pump and enqueue UX

- [x] 2.1 Refactor key reading so paint/event path can drain non-blocking keys without blocking; unit-test pump drains available bytes and leaves incomplete sequences
- [x] 2.2 Wire pump into `handle_agent_event`/`paint` while `S.busy` and no confirmation/ask; Enter enqueues steer + transcript user row + input clear; Alt+Enter enqueues follow-up; idle Alt+Enter still inserts newline
- [x] 2.3 Escape while busy: abort, clear queues, restore joined text to input (order preserved); unit-test restore order and empty-queue no-op
- [x] 2.4 Confirmation/ask still own keyboard first (no pump steal); regression test with open confirmation

## 3. Agent injection

- [x] 3.1 Add segment-boundary steer take (after tool step drain / before next LLM call); inject as user message + journal once; no second system prompt; unit-test injection point and journal
- [x] 3.2 After `turn.start` settles with no park, UI drains follow-ups in order via fresh turns; unit-test multi follow-up order and stop-on-error-banner path
- [x] 3.3 Retry path: steer not injected between retry attempts of the same segment; unit-test or extend existing retry scenarios

## 4. Shell prefix

- [x] 4.1 Parse `!` / `!!` in `commit_input` after slash resolution; bare `!` → error banner; unit-test parser
- [x] 4.2 Execute via shared run-tool path (workspace, timeout, env); render tool-style row with exit summary; unit-test row content
- [x] 4.3 `!` output feeds next agent context; `!!` does not touch history; unit-test history untouched for `!!`

## 5. Verification

- [x] 5.1 `make test` green
- [x] 5.2 Manual: stream + Enter steers; Alt+Enter follow-up runs after reply; Escape restores three lines; `!git status` / `!!echo hi` behave per spec; confirmation still blocks pump
