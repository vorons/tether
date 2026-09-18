# Tasks

## 1. Scroll vs history

- [x] 1.1 Remove the `if S.input == "" then history_prev/history_next`
  branches in `handle_key` for Up/Down; replace with transcript
  scroll (Up: `S.scroll + 1`, `user_scrolled = true`; Down: `S.scroll - 1`,
  follow mode when it hits 0). Verify: with empty input, Up/Down scroll
  the transcript and insert no text.
- [x] 1.2 Add Ctrl+Up / Ctrl+Down history-recall bindings in
  `handle_ctrl` (or the key reader's Ctrl-modifier path). Verify:
  Ctrl+Up recalls the most recent committed message, Ctrl+Down steps
  forward and clears at the end.

## 2. History recall walks the list

- [x] 2.1 Confirm `load_history` dedup keeps the full committed list
  (dedupe only exact consecutive repeats). Verify: five distinct
  committed messages yield five recall entries.
- [x] 2.2 Ensure `history_prev`/`history_next` step one entry per
  press from the most-recent (index `#S.history`) down to index 1
  and back to the sentinel. Verify: three Ctrl+Up presses on five
  entries land on the 3rd-most-recent.

## 3. Record only committed messages

- [x] 3.1 Move `session.add_history` / `push_history` so they run
  only in `commit_input` after the slash-command branch, on the
  committed text. Verify: typing and clearing a line without Enter
  records nothing; a submitted message does.
- [x] 3.2 Remove any remaining call site that records uncommitted
  typed text. Verify: grep shows a single call site (commit path).

## 4. Error overlay dismissal

- [x] 4.1 In `handle_overlay_key` for the `error` overlay, map Esc and
  Enter to close (`S.overlay = nil`, `S.overlay_data = nil`). Verify:
  after opening the error overlay, Esc dismisses it and the input
  field accepts typing.
- [x] 4.2 Confirm `commit_input` clears `S.error_banner` so a fresh
  submit after dismissal sends cleanly. Verify: dismiss → type →
  Enter sends the message and the banner is gone.

## 5. Docs and tests

- [x] 5.1 Update the help overlay / README key table: Up/Down =
  scroll, Ctrl+Up/Down = history. Verify: the overlay text matches.
- [x] 5.2 Add `tests/lua_tests.lua` cases: scroll-does-not-insert,
  recall-walks-list, discard-not-recorded, error-dismiss-then-send.
  Verify: `lua tests/lua_tests.lua` passes with the new cases.
- [x] 5.3 Run the host smoke test and full suite. Verify: `make test`
  is green.
