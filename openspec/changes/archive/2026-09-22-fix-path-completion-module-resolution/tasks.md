# Tasks

## 1. Make the tools lookup work in the binary

- [x] 1.1 Resolve the tools module through the host global in `path_complete_tab`, keeping the `require` fallback for the plain-Lua harness, verified by a pty run of the built binary where Tab now reaches the completion code instead of returning early
- [x] 1.2 Make `tools.path_complete` return candidates that carry the typed directory, verified by the pty run reaching `read src/tether/agent.lua` and by the existing tools test covering the directory cases
- [x] 1.3 Add a regression test that drives Tab completion with a real `tools` table and no `M._tools_stub`, covering the production lookup path, verified by the new test passing in `lua tests/lua_tests.lua`
- [x] 1.4 Move the existing `path_complete` test's directory expectations to the path-qualified contract and add a several-candidates case, verified by that test passing (and by no other test observing the bare-name form)

## 2. Verification and docs

- [x] 2.1 Run `make test` and fix any regression it reports
- [x] 2.2 Validate the change with `openspec validate fix-path-completion-module-resolution --strict` and confirm it reports no issues
- [x] 2.3 Record the module-resolution convention (host-registered globals; `require` only in the plain-Lua harness) in `docs/tech-spec.md`, verified by reading the updated key-decision entry
- [x] 2.4 Re-run the slash-palette pty check to confirm the palette work is unaffected by the tools change
