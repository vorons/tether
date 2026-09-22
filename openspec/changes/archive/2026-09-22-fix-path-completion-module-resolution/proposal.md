# Proposal

## Why

Tab path completion does not work in the shipped binary. `ui.lua` resolves the
tools module with `require("tools")`, but the host registers every Lua module
as a global (`load_module` in `src/host/main.c` calls `lua_setglobal` and never
`package.preload`), so the lookup yields `nil` and `path_complete_tab` returns
without doing anything.

The defect is invisible to the test suite: the Tab tests stub the module
through the `M._tools_stub` seam, so they exercise the completion logic while
the production lookup is never used. A pty run of the built binary with
`read src/tether/ag` + Tab completes nothing, while `openspec/specs/tui`
already requires that Tab complete the workspace-relative token.

Fixing only the lookup is not enough: with the lookup working, `Tab` on
`read src/tether/ag` completes to `read agent.lua`, because
`tools.path_complete` returns bare entry names while the UI replaces the whole
`src/tether/ag` token with the chosen candidate — the typed directory is lost.
`openspec/specs/tui` already pins the required outcome: with
`read src/tether/ag` and `src/tether/agent.lua` as the only match, the token
becomes `src/tether/agent.lua`. The repository also holds two contradictory
expectations about this contract: the UI test stub documents candidates as
full paths ("full path label as tools returns"), while the tools test expects
bare names. Only the path-qualified form can satisfy the requirement.

The same shape of bug was found in the earlier slash-palette work (skills were
resolved with `require("context")` and silently produced an empty list); this
change fixes the remaining instance and pins it with a test.

## What Changes

- Resolve the tools module through the host global first (`tools`), keeping the
  `require` fallback for the plain-Lua test harness, so the lookup works in
  both environments.
- Make `tools.path_complete` return candidates that carry the typed directory
  (`sub/inner.lua` for the token `sub/in`), so completing replaces the whole
  token with a workspace-relative path as the `tui` requirement demands. This
  settles the contradiction between the two existing tests on the contract.
- Add a regression test that drives Tab completion through the production path
  — a real `tools` table with no `M._tools_stub` — so a future change cannot
  reintroduce a lookup that only works under the stub.
- Record the module-resolution convention (globals registered by the host,
  `require` only in the harness) in `docs/tech-spec.md`, so the next module
  lookup does not repeat the mistake.

No requirement text changes: `tui`'s `Path completion` requirement already
mandates this behavior. The change is declared with `skip_specs: true` for that
reason — it restores conformance to an existing requirement instead of
altering it.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None. The behavior is already specified under `tui` → `Path completion`; only
the implementation changes, so no delta spec is written.

## Impact

- `src/tether/ui.lua`: the tools lookup in `path_complete_tab` (one call site;
  it is the only `require` left in `src/`).
- `src/tether/tools.lua`: the candidate label in `path_complete` (its only
  consumer is the UI, so nothing else observes the change).
- `tests/lua_tests.lua`: a regression test for the production lookup path, and
  the directory expectations in the existing `path_complete` test moved to the
  path-qualified contract (including a several-candidates case).
- `docs/tech-spec.md`: the module-resolution convention.
- Users: Tab starts completing paths in the binary again.
