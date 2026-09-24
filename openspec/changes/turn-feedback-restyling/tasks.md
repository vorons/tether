# Tasks

## 1. Transcript

- [x] 1.1 Drop `placeholder_entry` from `transcript.lua` (third tail in `tails`/`visible_count`/`entry_at`/`sync_tail`/`clear`); verify `lua tests/lua_tests.lua` still parses (failing placeholder tests expected — reworked in 3.1)
- [ ] 1.2 Stamp `started_at` when a thinking entry is created in `transcript.handle`; verify a `reasoning_delta` entry carries `started_at` and later deltas do not reset it

## 2. Rendering

- [x] 2.1 `render_input`: busy branch shows only spinner frame + `Working...` (secret mode keeps its masked line); verify painted input row contains `Working...` while busy and normal text when idle
- [x] 2.2 Delete the placeholder row branch and the live-tail spinner append; verify no transcript row contains `думает` in any busy state
- [x] 2.3 Thinking rows render `think · Ns` with live elapsed (collapsed one-liner keeps the toggle hint); verify header matches `think · %d+%.0s`
- [x] 2.4 Assistant prefix `● ` → `·` (`-` in ASCII mode, `·`→`-` in GLYPH_MAP); verify rendered assistant row starts with the marker in both modes

## 3. Tests

- [x] 3.1 Rework placeholder-lifecycle blocks to the new spec (T54/T88/T90/T124/T125/T129, pi 4.1 busy indicator); verify each asserts Working-indicator presence/absence instead of placeholder rows
- [x] 3.2 Run full `make test` green (luac, lua/context suites, e2e, host smoke/primitives)
