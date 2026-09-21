# Tasks

## 1. Diff engine (`src/tether/diff.lua`)

- [x] 1.1 Create the pure-Lua module with `unified(old_text, new_text)` returning unified-diff text plus `{add, del}` counts (line-level LCS grouped into hunks with context); verify unit tests cover a new file (all additions, `+N −0`), an overwrite with surrounding context, and identical input (empty diff)
- [x] 1.2 Add `parse(diff_text)` returning renderable rows (kind = context/add/remove/hunk-header/file-header, old and new line numbers derived from `@@ -a,b +c,d @@`, text) and `nil` for text that is not a unified diff; verify unit tests cover a multi-file diff, a hunk without explicit counts and a `\ No newline at end of file` marker
- [x] 1.3 Add `pair_words(removed_row, added_row)` implementing conservative pairing (same-length runs only, similarity threshold, skip beyond the column threshold) and returning the emphasised segments; verify unit tests for the only-changed-word case, a dissimilar pair, an over-long line and unequal run lengths
- [x] 1.4 Add `meter(add, del)` returning the proportional block counts with at least one block per non-zero side; verify unit tests for `+12 −3`, `+34 −0` and `+0 −5`
- [x] 1.5 Wire the module into the build and the harnesses: add it to `LUA_MODS` and the embed invocation in `Makefile`, add its `load_module` entry in `src/host/main.c` before `agent`/`ui`, and expose it in the `tests/lua_tests.lua` module loaders; verify `make` regenerates `src/host/embed.c`, `luac -p src/tether/diff.lua` passes, and a `dofile`-based test calls the module

## 2. Agent: arguments, projection and diff bodies

- [x] 2.1 Emit the parsed arguments on `tool_call_start` next to `id` and `name`; verify a test asserts the event carries `args` for a tool call
- [x] 2.2 Compute the read-only projection for `write`/`patch` (target resolved through the existing tools resolution helpers, inside the workspace, at most 1 MiB, no write, no history or journal entry) and attach it to the event; verify tests cover an existing file, a new file, a patch, an oversized target (not read), a target outside the workspace, and that the file and history are unchanged afterwards
- [x] 2.3 Make the `write` and `patch` result bodies the applied unified diff, reusing the before-content read for the projection, with the one-line summary `+N −M` and a created/overwritten distinction for `write`; verify tests that the body is a diff and that the model's history carries the same text
- [x] 2.4 Keep the fallbacks honest: unreadable previous content falls back to the previous body (written path for `write`, applied-file list for `patch`) with no diff counts in the summary, and a failed call keeps its error body; verify tests for both
- [x] 2.5 Verify the rest of the agent contract is untouched: other tools keep their bodies and summaries, `TOOL_BODY_MAX` truncation still applies, and the existing agent-core tests pass

## 3. UI: rows, sanitization and expansion

- [x] 3.1 Render the status marker `✓` / `✗` / pending (ASCII `[ok]` / `[x]` / `…`) and append the clipped first error line to a failed row while the full error body moves behind expansion; verify a frame test where a 60-column failed `run` row is exactly one row holding the clipped first line, plus an ASCII-marker test
- [x] 3.2 Add `sanitize_output()` (drop everything but SGR; no cursor moves, erase sequences, carriage returns or OSC/DCS) and blank-line-run collapsing, applied at render time only; verify unit tests for stripping, SGR surviving while colour is on, nothing surviving when colour is off, and the stored body staying raw
- [x] 3.3 Add the expansion state model (per-entry `expanded`/`collapsed` overriding the inherited all-entries flag), bind `Ctrl+O` to the newest tool entry overlapping the viewport (falling back to the newest entry) and `Ctrl+Shift+O` to the all-entries toggle that clears per-entry state, and keep `Ctrl+O` as the all-entries toggle where the terminal reports no Shift modifier; verify key-decoding and frame tests for every spec scenario
- [x] 3.4 Toggle the clicked entry on a left click over a tool row where the mouse mode delivers transcript clicks, and deliver nothing in `auto`/`off`/`selection`; verify a click test plus a test that `auto` leaves the entry unchanged
- [x] 3.5 Update the `KEYMAP` table and any assertion that pins the `Ctrl+O` meaning; verify the keymap tests pass with the new bindings

## 4. UI: highlighting, diffs and preview

- [x] 4.1 Add the extension→language map and highlight expanded `read`/`grep` bodies with the existing tokenizer (one state across the body, `lineno<TAB>` and `path:line:` prefixes outside the coloured span), leaving `list`/`glob`/`run` plain; verify frame tests for a coloured Lua read, a coloured grep row, an unknown extension, and the strip-equality plus identical-geometry invariant
- [x] 4.2 Render `write`/`patch` bodies through `diff.parse`: line-number gutter, add/remove/context roles, syntax colouring by the target path, hunk and file headers, unchanged caps and the `… (N строк скрыто)` marker for long diffs; verify frame tests including the fallback to plain text for a body that does not parse as a diff
- [x] 4.3 Apply word-level emphasis from `pair_words` (changed words keep the add/remove role, carried-over words take the muted role) and render without emphasis under a colour-free theme; verify frame tests for the paired, unequal-run, dissimilar and over-long-line cases
- [x] 4.4 Render the write/patch summary with the `+N −M` meter and the created/overwritten wording; verify frame tests for `+12 −3`, created `+34 −0` and a zero side having no blocks
- [x] 4.5 Render a supplied projection on a pending `write`/`patch` entry (expandable like any body, same highlighting and caps), replace it with the executed result when the call finishes, and drop it when the call is denied, cancelled or aborted while leaving rows without a projection unchanged; verify frame tests for each of those transitions
- [x] 4.6 Verify the virtualization invariants hold with the new row shapes: a per-entry toggle keeps `_render_all` parity, the transcript height and hidden-row count stay exact while scrolled up, and a large diff respects the retained-row cache bound

## 5. Verification and docs

- [x] 5.1 Run `make test` and verify every stage passes (luac, unit, context, e2e, host smoke, host primitives)
- [x] 5.2 Run `openspec validate pretty-transcript-rendering --strict` and verify it passes
- [x] 5.3 Check the built binary under a pty: collapsed rows carry `✓`/`✗`, a failure shows its first error line, `Ctrl+O` toggles one entry, `Ctrl+Shift+O` toggles all, a pending write previews its diff before running, and an expanded write shows a numbered coloured diff; with `NO_COLOR=1` (or the `mono` theme) verify no SGR and no non-ASCII glyph appears
- [x] 5.4 Update `docs/design.md` (§6.3 blocks table, §6.5 collapse/summary, §6.11 diff overlay reuse, §6.13 status/key descriptions), `README.md` and `docs/tech-spec.md` for the glyphs, expansion keys, diff rendering and preview, and verify the docs match the implemented behavior
