# Tasks

## 1. Fix the cursor arithmetic

- [x] 1.1 Make the cursor assignment in `completion_apply` zero-based so it lands directly after the applied candidate (before any tail that follows the token), verified by a test asserting the cursor equals the position after the completion and never exceeds `#input`
- [x] 1.2 Make the cursor assignment in `completion_cancel` zero-based so Esc leaves it directly after the restored token, verified by a test asserting the same on the Esc path
- [x] 1.3 Assert the cursor on the production-lookup path (the test that completes through the host `tools` global) now that the behavior is specified, verified by that test passing

## 2. Verification and docs

- [x] 2.1 Run `make test` and fix any regression it reports
- [x] 2.2 Validate the change with `openspec validate fix-path-completion-cursor --strict` and confirm it reports no issues
- [x] 2.3 Check the built binary in a pty: complete `read src/tether/ag` with Tab, press Backspace, and confirm the input row loses the last character of `src/tether/agent.lua` (which the previous cursor position could not do)

## 3. Text after the token (found by verification)

The one-shot branch dropped the text typed after the token, so the cursor rule
was unobservable there and "complete the token in place" was violated mid-line.

- [x] 3.1 Carry the text after the token through the one-shot path in `path_complete_tab` (`tail`, as the palette branch already does), verified by the stub test asserting the tail survives and the cursor sits before it (T74)
- [x] 3.2 Cover the same on the production lookup path (the test completing through the host `tools` global): a token followed by `.bak` completes to `src/tether/agent.lua.bak` with the cursor before the tail and never at the end of the input (T84)
- [x] 3.3 Confirm the new tests fail against the unfixed code (the stub assertion reported the dropped tail), then pass with the fix
- [x] 3.4 Re-run `make test`, `openspec validate fix-path-completion-cursor --strict` and the pty probe on the built binary, checking the pty now keeps the text typed after the token
