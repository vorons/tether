# Proposal

## Why

After a Tab completion the cursor lands one position past the end of the input.
`completion_apply` sets `S.cursor = comp.start + #replace`, but `comp.start` is a
one-based position while `S.cursor` is a zero-based offset everywhere else
(`input_clear` sets 0, the palette sets `#S.input`, `input_insert` inserts at
`S.cursor + 1`). Completing `read src/tether/ag` therefore leaves the cursor at
21 for a 20-character line, and the first Backspace afterwards deletes nothing.

`completion_cancel` restores the token with the same arithmetic, so the Esc path
is off by one too, and the same happens when cycling candidates.

The requirement never stated where the cursor should end up, so the behavior is
unspecified rather than contradicted — this change states it and makes the code
match.

## What Changes

- Fix the cursor arithmetic in both completion paths (`completion_apply`,
  `completion_cancel`) so the cursor is zero-based and never moves past the end
  of the input.
- Add the rule to `tui`'s `Path completion` requirement: after applying a
  candidate the cursor sits immediately after it, before any text that follows
  the token, and after Esc it sits immediately after the restored token.
- Keep the text typed after the token: the one-shot branch of
  `path_complete_tab` did not carry the tail, so a unique candidate replaced the
  rest of the line and the cursor rule could not be observed there at all. The
  candidate now completes the token in place and leaves that text alone.
- Cover the applied, cycled and restored paths with tests, including the pty
  check where Backspace after Tab removes the last character of the completed
  path.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `tui`: the `Path completion` requirement gains the cursor rule and its
  scenarios (cursor after an applied candidate, cursor after Esc).

## Impact

- `src/tether/ui.lua`: the cursor assignment in `completion_apply` and
  `completion_cancel` (two lines), plus the `tail` of the one-shot completion in
  `path_complete_tab`.
- `tests/lua_tests.lua`: cursor assertions on the completion paths, including
  the production-lookup test, and a case where text follows the completed token.
- `tui`'s `Path completion`: the unique-candidate bullet now says the text after
  the token is left unchanged, with a scenario for it.
- Users: the cursor sits where the completion ended, so Backspace and further
  typing behave as expected.
