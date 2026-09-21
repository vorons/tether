# Tasks

## 1. One palette list

- [x] 1.1 Remove the `/skills` entry from the command table and update the command-count test, verified by `lua tests/lua_tests.lua` (T39) reporting the remaining commands
- [x] 1.2 Add a palette skill resolver that maps `context.discover_skills` output to entry rows (`/<name>` label, description, `[задача]` hint, skill flag), drops names colliding with a command name case-insensitively, and falls back to no rows on a discovery error, verified by a unit test covering two skills, a colliding name and its case variant, and a failing discovery (stubbed via `M._skills_stub`)
- [x] 1.3 Resolve the skill rows once when the palette opens and reuse them while it stays open, verified by a test showing the stub is called once across several keystrokes and again after the palette closes and reopens
- [x] 1.4 Build and rank one combined list (commands in declared order, then skills in discovery order) in the palette sync, verified by tests that typing `/` lists commands followed by skills, `/dep` selects skill `deploy`, and a prefix match still outranks an interior match

## 2. Scrolling window and overflow indicator

- [x] 2.1 Add a pure window helper (`min(8, floor(h / 2))` rows, never below one, and an offset that keeps the selection inside) verified by unit tests over long lists, first/last selection, and a 12-row terminal
- [x] 2.2 Render the palette as a window over the ranked list instead of its first rows, verified by a frame test asserting the painted rows follow the selection
- [x] 2.3 Draw the dim `sel/total` indicator on the spare row the palette region already reserves when the list exceeds the window, and omit it when that row is not inside the region (short terminal), verified by frame tests that the row carries digits and `/` only, that no entry row is lost, and that neither the separator nor the status row is ever painted by the palette
- [x] 2.4 Feed the window height into the layout so the footer budget still matches the painted rows, verified by the existing footer-budget and separator tests plus a frame test on an 8-row terminal
- [x] 2.5 Map palette mouse presses through the window offset and make an indicator press a no-op, verified by a click test on a list longer than the window

## 3. Argument hints

- [x] 3.1 Render an entry's argument hint after its name when it declares one, verified by a frame test showing `[задача]` on a skill row and no hint on a command row

## 4. Skill selection and submission

- [x] 4.1 Make Enter and Tab on a skill row only compose `/<name> ` into the input (cursor at end, palette closed, nothing executed, no body read), verified by a test asserting the input text, the absence of agent traffic and an unchanged transcript
- [x] 4.2 Route a submitted `/<word>` that names a discovered skill to the agent as an ordinary user message while commands keep executing and unknown tokens keep the existing path, comparing names without regard to case on both lookups, verified by tests for a skill name, a different-case skill name, a different-case command name (`/CLEAR` runs clear), a skill hidden by a command collision (`/COPY` with skill `copy` discovered runs the command), and an unknown token
- [x] 4.3 Delete the `/skills` palette mode: its key branch, its mouse path, its `_in_skills_palette` guard, the `[skill: …]` reference and its command handler, verified by `grep` finding no `_in_skills_palette` or `palette_mode == "skills"` left and by the rewritten tests passing

## 5. Verification and documentation

- [x] 5.1 Rewrite the retired skills-palette tests (T79–T81) as unified-palette tests (listing, filtering, selection, collision, discovery failure) with discovery stubbed, verified by `lua tests/lua_tests.lua` passing
- [x] 5.2 Run the full suite with `make test` and fix any regression it reports
- [x] 5.3 Validate the change with `openspec validate unified-slash-palette --strict` and confirm it reports no issues
- [x] 5.4 Check the built binary in a pty: type `/` with a skill directory present, confirm the skill row with its hint, scroll a long list with Down and confirm the indicator, select the skill and confirm the input text, then repeat under `NO_COLOR`/ASCII mode
- [x] 5.5 Update `README.md`, `docs/design.md` (palette sections and the removed `/skills` entry) and `docs/tech-spec.md` (UI regions, key/behavior tables) to describe the unified palette, the window, the hints and the removal
