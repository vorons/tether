# Tasks

## 1. Transcript entry model and virtualization

- [x] 1.1 Give each transcript entry render state (`rows`, `rows_w`, `rows_ver`, `height`) so rows are cached per entry instead of in the single flat `S.transcript_cache`; verify with a unit test that one entry's rendered rows equal the current full-render output for a fixed transcript
- [x] 1.2 Add the incremental height index (O(1) append, repair from the first changed entry) and export `ui.transcript_height`; verify with unit tests asserting exact height after append, in-place entry mutation, `/clear` and `/new`
- [x] 1.3 Rewrite `render_transcript` to walk the height index, render only entries overlapping the viewport, and slice partially visible entries by row offset, keeping the existing width/scroll invalidation; verify by counting `render_entry` calls per repaint in a frame-capture test at top/middle/bottom scroll offsets
- [x] 1.4 Bound the wrapped-row cache (`max(4 × viewport, 1024)` rows, LRU eviction, re-derive on demand) and expose a `cache_rows` seam; verify with a synthetic 50k-row transcript test asserting cached rows stay under the bound and that revisiting an entry after eviction renders identical rows
- [x] 1.5 Export a render-everything seam (`_render_all`) and add the parity test: virtualized rows equal full-render rows for a transcript mixing prose, tool bodies and one very long entry; verify the parity test passes
- [x] 1.6 Verify follow mode, `Ctrl+O`, `Ctrl+T`, `/clear`, `/new` and resize keep height, hidden-row count and visible rows exact through the `run_ui_with` harness

## 2. Navigation and readability

- [x] 2.1 Insert a `separator` entry (local HH:MM) before each new user turn on submit, without touching agent history; verify with a unit test asserting one separator per turn, in chronological order, no separator in `agent.get_history()`, and no separators left after `/clear` and `/new`
- [x] 2.2 Render separator entries dim in the existing frame style (`── HH:MM ──`, ASCII `-- HH:MM --`); verify with frame-capture assertions in both color modes
- [x] 2.3 Gate separators behind `ui.turn_separators` (default true) and skip them for `-r` and `/resume` restored transcripts; verify with tests for the disabled config and for restored sessions
- [x] 2.4 Paint the right-aligned in-transcript `↓ новые +N` marker on the newest visible row, omitting it when the count is zero, the row is too narrow, or an overlay is open, and rendering it as `v новые +N` in ASCII mode; verify with frame tests for scrolled-up, follow mode, narrow width and ASCII mode
- [x] 2.5 Make the marker and the status line read one shared count so they can never disagree; verify both report the same N in the marker test

## 3. Palette: fuzzy matching and modes

- [x] 3.1 Extract and export `fuzzy_match`/`fuzzy_score` (subsequence, prefix ranked first, declaration-order ties, empty filter lists all); verify with table-driven tests including `/mdl` listing `/model` first and `/m` still selecting `/model`
- [x] 3.2 Replace the prefix-only filter in `palette_sync` with fuzzy ranking; verify with tests for empty-filter order and for a no-match result of zero items
- [x] 3.3 Introduce `S.palette_mode` and route rendering, Enter, Tab and mouse hit-testing through it (`"command"` first); verify existing palette tests plus a mouse-click test per mode
- [x] 3.4 Render label and description for every palette row (truncated to width) with the selected row in accent style; verify with a frame capture asserting the description appears and a narrow terminal truncates instead of overflowing
- [x] 3.5 Keep Enter with no match from running a command or submitting the input, and keep a space closing the palette; verify with key-dispatch tests for `/zzz` + Enter and `/model ` (trailing space)

## 4. Path completion

- [x] 4.1 Add token extraction (from the cursor back to whitespace, leading `@` preserved) and candidate listing through `tools.list` with a 200-entry cap and a truncation flag; verify with unit tests for `src/te`, `@src/te`, refusal of absolute and `..` tokens, and dotfile gating
- [x] 4.2 Implement Tab outside the palette: unique candidate completes in place, multiple candidates open the path palette with the first applied, repeated Tab cycles (wrapping), Esc restores the token as typed, any other key clears the completion state; verify with harness tests driving Tab/Tab/Esc byte sequences and asserting the input text, the palette items, and that no agent call was made
- [x] 4.3 Gate completion behind `ui.path_completion` and keep Tab's command-completion meaning inside an open palette; verify with a disabled-config test and a palette-mode Tab test
- [x] 4.4 Emit directory candidates with a trailing `/` and allow completing again inside them; verify with a harness test completing `src` → `src/` → an entry inside `src`

## 5. Copy targets and toast

- [x] 5.1 Build `copy_targets(transcript)` (last answer, last tool output, last fenced block, whole transcript) newest-first with byte sizes and omission of empty sources; verify with unit tests per target, per size and for an empty transcript
- [x] 5.2 Add `/copy` as a palette mode rendering those targets and wiring Enter to the existing OSC 52 path; verify with a frame test showing the rows and a captured write containing the base64 payload of the selected target
- [x] 5.3 Assert copied text contains no SGR sequences (strip-based comparison) and that `Ctrl+Shift+C` still copies the last answer directly without opening a palette; verify both tests
- [x] 5.4 Add the `S.toast` confirmation rendered as the status line's leading field, repainted immediately on copy and cleared by the next keypress with no background timer; verify with a frame capture showing the toast in the copy frame and its absence after the next key

## 6. Skills in the palette

- [x] 6.1 Add `/skills` listing discovered skills (name + description, discovery order, explicit empty state on none or on discovery failure); verify with tests using stubbed discovery returning two skills and returning none
- [x] 6.2 Make selecting a skill append a reference naming the skill and its `SKILL.md` path to the input, never the body; verify with a harness test asserting the input holds the name and path and not the body text
- [x] 6.3 Confirm Enter on the empty state changes nothing; verify with a key-dispatch test

## 7. Code block syntax highlighting

- [x] 7.1 Add color-depth negotiation from `COLORTERM` (truecolor / 256 / 16, exported seam) and depth-aware theme token roles that default to today's 16-color codes; verify with tests for `COLORTERM=truecolor`, `COLORTERM=24bit`, unset, and for `mono` emitting no SGR
- [x] 7.2 Implement the ordered per-line token scanner for lua, c/h, sh/bash, python, js/ts, go, rust and json covering comments (with block-comment state), strings, numbers and keywords; verify with per-language tests on sample blocks asserting the token kinds
- [x] 7.3 Wire highlighting into `md_render` for fenced blocks, tokenizing before wrapping, honoring `ui.highlight` (`"auto"`/`"on"`/`"off"`) and the ASCII, `NO_COLOR` and `mono` precedence; verify with frame tests for each mode and a case-insensitive fence label (` ```LUA `)
- [x] 7.4 Assert the text invariant: stripping SGR from a highlighted block equals the plain render and every row keeps the same display width; verify the test passes for every supported language
- [x] 7.5 Verify an unknown or absent fence language renders uncolored and that a 500-line highlighted block still paints only its visible rows; verify with frame-capture tests

## 8. Config, docs and full verification

- [x] 8.1 Add `ui.highlight = "auto"`, `ui.turn_separators = true` and `ui.path_completion = true` to the config defaults; verify with config unit tests asserting the new keys and that a partial `ui` override leaves them intact
- [x] 8.2 Update `README.md` (TUI features and config keys) and `docs/design.md` §6/§10 to match the implemented behavior and defaults, including the live-turn-feedback paragraph that landed with the repaint primitive; verify by reading both against the code and grepping the new keys
- [x] 8.3 Update any existing test assertions invalidated by separator rows and run the full suite; verify `make test` exits 0 (luac parse, unit tests, context tests, e2e, host smoke)

## 9. Live turn feedback

Implementation of this group already sits in the working tree (the repaint primitive, waiting/streaming state, placeholder, caret and busy status field). These tasks bring it under the spec instead of re-implementing it.

- [x] 9.1 Assert the waiting frame: the placeholder row and spinner are painted before the first token, and both are gone once the first text or reasoning delta arrives; verify with a frame-capture test extending the existing live-turn-feedback coverage
- [x] 9.2 Assert the caret: it sits at the end of the newest line while deltas arrive, is not drawn while the user has scrolled up or an overlay is open, and is `|` in ASCII mode with ASCII spinner frames; verify with frame tests
- [x] 9.3 Assert lifecycle clearing: the placeholder, caret and elapsed field are cleared after a reply, an error, an abort, and when a confirmation menu is raised, and that a turn resumed after a confirmation decision shows the same feedback; verify with frame tests per case
- [x] 9.4 Assert the throttle: transitions (tool call start, tool result, error, confirmation) always paint, and a stream of N deltas paints at most the bounded number of frames; verify with a multi-delta test counting painted frames and asserting the per-turn elapsed counter resets each turn
