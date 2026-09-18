# Design

## Context

See `proposal.md` — Why for motivation and the spec deltas for requirements.

Current constraints that shape the approach (all in `src/tether/ui.lua`, ~2.4k lines,
no C host changes possible without touching `src/host`):

- The transcript is a flat array of entries (`user`, `assistant`, `thinking`, `tool`,
  `system`) plus a single global wrapped-row cache: `display_lines()` renders **every**
  entry into `S.transcript_cache` and keys it on `S.transcript_ver`. Scroll math
  (`render_transcript`, `scroll_indicator`) reads `#display_lines()`, so height and
  content come from the same full render.
- The redraw loop is a line diff against `S.screen` plus DECSTBM scroll shifts; the
  row diff is invalidated wholesale when the viewport top or width changes.
- Keys arrive as `{kind=...}` records decoded in `read_key()`. Shift-modified
  printable keys need per-protocol encodings (kitty `CSI <params> u`, x11
  `CSI 1;2<letter>`) and the code already special-cases them for `Ctrl+Shift+C`.
- The palette (`S.palette_active`/`S.palette_items`) is a single list rendered in the
  palette region; `/model` and `/resume` are *overlays*, not palette modes. Palette
  filtering is prefix-only (`name:find(filter, 1, true) == 1`) and `Tab` is handled
  only inside the palette.
- `md_render()` already parses the fence info string (` ```lang `) into `lang` and
  uses it only for the frame label; token text is rendered uncolored.
- Copy support exists for one target only: `Ctrl+Shift+C` → `copy_last_assistant()`
  writes `OSC 52` with a local `b64encode`. There is no toast, and no timer: the
  main loop blocks in `tether.read_char()`, so nothing repaints while idle.
- Structured workspace listing already exists (`tools.list` → `{entries, count}`),
  and skills discovery already exists (`context.discover_skills`).
- Live turn feedback already exists in the working tree (not committed when this
design was written): `paint(force)` repaints from inside the agent event path with a
delta throttle, `S.waiting`/`S.streaming` drive a `✻ tether думает…` placeholder and a
`▌` caret, and the status line leads with a spinner and elapsed seconds. This change
documents that behavior instead of rebuilding it — see the Live turn feedback
requirement and task group 9.

## Goals / Non-Goals

**Goals:**

- Keep every new behavior reachable through the existing redraw/diff loop — no C host
  changes, no background threads, no new dependencies.
- Make transcript rendering cost viewport-proportional and memory bounded, without
  changing a single visible row.
- Put new user-facing surfaces where they are protocol-independent and testable: the
  palette region and an exported pure-function seam, not new multi-key bindings.
- Preserve the project's test style: pure functions exported on `M`, driven from
  `tests/lua_tests.lua` (the `run_ui_with(bytes, stubs, sink)` harness already
  captures painted frames).

**Non-Goals:**

- Re-adding the help/status/log overlays or slash commands removed in M9.
- A background repaint timer (deltas already drive repaints; a redraw timer is a
  separate change because it needs a non-blocking `read_char`/timeout in the C host).
- Inline-code coloring, more themes, images, in-app drag selection, multi-session
  tabs.
- Changing the agent, provider, session, or tools contracts.

## Decisions

### 1. Per-entry wrapped-row cache with an incremental height index (virtualization)

Replace the single flat `S.transcript_cache` with a per-entry model. Each entry keeps
`rows` (rendered rows), `rows_w` (the width they were wrapped at), `rows_ver` (content
version, bumped by `bump_transcript`-style mutations), and `height` (`#rows`).

- `render_transcript` walks a prefix-sum array of heights to find the first entry that
  overlaps the viewport top, renders forward until the region is filled, and slices
  partially visible entries by row offset. Only visible entries are (re-)rendered.
- The height index is appended to on new turns and repaired from the first changed
  entry onward when an existing entry changes height (expand toggle, tool result,
  width change). Appends are O(1); a mid-transcript change is O(entries − index), never
  per repaint.
- Cache eviction: keep total cached rows under a bound of `max(4 × viewport, 1024)`
  rows, evicting least-recently-visible entries; anything evicted is re-derived on
  demand. Bounding the *total* rather than each entry is what keeps one huge entry
  (a long assistant answer) from pinning memory.

Alternatives considered: (a) LRU over the existing flat array — rejected, the height
and the content would then come from different sources and the scroll math would need
its own rescan; (b) a Fenwick tree over heights — rejected as unnecessary complexity
for a single-threaded UI that changes height a handful of times per turn; (c) windowed
caching only (no entry heights kept) — rejected, `/clear`-free scroll indicator math
needs an exact total.

Parity is structural, not incidental: the virtualized path is the only path, and tests
compare it against an exported `_render_all` seam (render-everything) at several scroll
offsets.

### 2. Turn separators are entries, not decoration on the user row

A separator is a transcript entry with `role = "separator"` and `text = "14:32"`,
inserted immediately before the user entry. It inherits scrolling, height accounting,
copy ("whole transcript"), ASCII downgrade and theming from the existing renderer.

Alternative considered: an `at` timestamp field on user entries, decorated by the
renderer. Rejected because it hides a real row inside another entry's row list, which
makes the height slice logic and the "whole transcript" copy asymmetric (a separator
would appear or not depending on whether user entries are rendered).

`ui.turn_separators = false` skips creating the entry altogether, so heights, copy and
scroll math are consistent in both modes. Restored sessions get no separators because
the restored history carries no submission times — synthesizing one (for example
`--:--`) was rejected as noise.

### 3. The "new below" marker is painted, never stored

The in-transcript `↓ новые +N` marker is painted by `render_transcript` onto the newest
visible row, right-aligned, whenever `S.user_scrolled` and the count is non-zero. It is
deliberately **not** a transcript row: storing it would change the height it reports and
would re-render every frame. The existing `scroll_indicator()` supplies the count from
the height index (O(1)); the marker is dropped when the row lacks room
(`vlen(row) + 1 + vlen(marker) > width`) or when an overlay is open, and ASCII mode
downgrades it through the existing glyph map.

### 4. Path completion on Tab, rendered in the palette region

- Token = the text from the cursor back to the previous whitespace (or line start),
  with a leading `@` treated as a mention prefix and preserved.
- Candidates come from `tools.list({ path = dir })` called with a workspace-relative
  directory (no new listing code, no cache: `ls` is cheap and the list is capped at
  200). The workspace guarantee is inherited from the tool's own resolution, and
  `..`/absolute/`~` tokens are refused before listing, so no candidate can come from
  outside the workspace.
- Directories are emitted with a trailing `/`; hidden entries are only offered when the
  typed token starts with `.`.
- Palette reuse: `S.palette_mode` selects the list being shown
  (`"command" | "path" | "copy" | "skill"`; `/model` and `/resume` stay overlays),
  and
  `S.completion = { start, stop, original, items, sel }` holds the editing state. One
  Tab applies the first candidate (so the user sees what is happening) and later Tabs
  cycle; Esc restores `original`; any other key clears the completion state and keeps
  the applied text. This reuses the palette's rendering, mouse hit-testing and hint
  behavior instead of adding a parallel list region.

Alternative considered: an `@`-only trigger. Rejected — Tab on a bare path is the common
case, and `@` is already meaningful text; the `@` prefix is preserved rather than
required.

### 5. Wider copy goes through `/copy`, not new Shift-modified keys

Every new Shift-modified printable key would need a kitty/x11/plain encoding branch in
`read_key` (the code already carries three such branches for `Ctrl+Shift+C` and
`Ctrl+Up/Down`). A palette entry is protocol-independent, discoverable through `/`,
and reuses the same picker machinery as item 4. `Ctrl+Shift+C` keeps its current
meaning as the fast path.

Copy sources are read from the entry model, not from the render: last assistant text,
last tool output (the tool entry's body), last fenced block (the same fence scanner the
renderer uses), whole transcript (entries' source text in display order, separators as
`── HH:MM ──`). Plain text therefore has no escapes by construction.

The confirmation toast is `S.toast = { text }`, rendered as the status line's leading
field and cleared by the next keypress in `handle_key`. A TTL-based fade is explicitly
out of scope: without a timer nothing repaints while idle, so a TTL would either lie or
need the C host change listed under Non-Goals. The copy repaint reuses `paint(true)`
(the turn-feedback primitive) so the toast is visible immediately.

### 6. Syntax highlighting: ordered per-line scanner with depth-aware theme roles

`md_render` keeps its structure and gains a token pass for fenced blocks when the fence
language is supported. Rules per language are an ordered list applied left to right,
first match wins, so strings and comments beat keywords and a keyword inside a string is
never re-colored:

1. line comment (language-specific marker), 2. block comment (state carried across the
lines of the block), 3. string literal (with escape handling; Lua long brackets
included), 4. number, 5. keyword (word-boundary), 6. everything else plain.

The scanner is a single pass per line with plain `find`/`match` on literal markers —
no backtracking patterns, matching the project's parser lesson. Not a real lexer, so
constructs like nested block comments or heredocs are not tracked: acceptable because
the failure mode is cosmetic.

Colors come from the theme as new roles (`code_comment`, `code_string`, `code_number`,
`code_keyword`) resolved through a depth-aware `sgr_role`: 16-color codes (the current
theme values), 256-color codes, or 24-bit codes chosen once at startup from `COLORTERM`
(else `TERM`), with `mono`/ASCII/`NO_COLOR` producing no SGR at all. Tokenizing happens
**before** wrapping: `cells()` already consumes SGR sequences as zero-width cells, so
wrapping and `vlen`-based padding stay correct, and the frame geometry is unchanged.

Alternative considered: highlight after wrapping (rejected — a wrap boundary inside a
token would then be re-tokenized per row and could split a sequence), and reusing an
external grammar/lexer (rejected — no dependencies, no `load`).

### 7. Palette matching becomes fuzzy, ranking stays deterministic

`ui.fuzzy_match(text, pattern)` returns a boolean plus a score: prefix match scores
above a match that starts later, and earlier/interior matches score above later ones;
ties fall back to the declared command order. Empty filter keeps declaration order. The
same function serves `/copy`, `/skills` and path candidates (where the filter applies to
the path tail), so matching behaves identically across palette modes.

### 8. Live turn feedback is specified, not rebuilt

`agent.turn` runs synchronously inside the submit handler, so before this work the
main loop's `redraw()` never fired mid-turn and the whole answer appeared at once. The
shipped fix repaints from the event path through `paint(force)`, throttled by a
counter of skipped deltas (and a CPU-time floor), with state transitions forcing a
repaint. Two consequences are baked into the requirement rather than hidden: the
placeholder/caret state is a pair of flags (`S.waiting`, `S.streaming`) that the event
handler clears on the first delta and at turn end, and no background timer exists, so
the spinner advances only when something drives a repaint.

Alternatives considered: (a) a redraw timer loop — rejected for this change, it needs
a non-blocking `read_char`/timeout in the C host (see Non-Goals); (b) repainting on
every delta — rejected, it multiplies work on large transcripts and slowdowns on slow
terminals; (c) appending a real transcript entry for the placeholder — rejected, it
would have to be removed on the first delta and would perturb heights and the
scroll-back count.

Making this contractual also fixes a documentation gap: the behavior shipped with
README and test edits but no requirement, so nothing kept it from regressing.

### 9. Config, exports and tests

- `config.default_config()` gains `ui.highlight = "auto"`, `ui.turn_separators = true`,
  `ui.path_completion = true`; each gates only its own feature, so a user can restore
  the previous behavior key by key.
- New exports follow the existing seam style: `fuzzy_match`/`fuzzy_score`,
  `path_candidates`, `copy_targets`, `highlight_line` (+ `TOKEN_RULES`),
  `transcript_height`, `_render_all`, `depth_from_env`.
- Tests extend `tests/lua_tests.lua` with pure-function tests plus `run_ui_with(...,
  sink)` frame assertions (separators, marker, toast, completion cycling, copy payload);
  a synthetic 50k-row transcript backs the viewport-bound test, which counts
  `render_entry` calls per repaint instead of measuring wall time.
- `README.md` (TUI features, config) and `docs/design.md` §6/§10 are updated in the
  same change so the documented design does not drift from behavior.

## Risks / Trade-offs

- [Replacing the flat cache is the riskiest edit — an off-by-one at viewport edges
  leaks stale or shifted rows] → one render path plus an exported `_render_all` parity
  test at several scroll offsets, and the existing width/scroll invalidation in
  `render_transcript` is kept.
- [Separator rows change what existing render tests and screenshots expect] →
  update those assertions in the same change; `ui.turn_separators = false` restores the
  old transcript exactly.
- [Memory bound vs scroll-back cost: evicted entries are re-wrapped on return] →
  bound is `max(4 × viewport, 1024)` cached rows with LRU eviction, so re-derivation is
  limited to what is on screen; the parity test asserts identical rows after a
  round trip.
- [Highlighting miscolors (keyword inside a string, `#` meaning comment or preprocessor
  depending on language)] → ordered first-match-wins scanner with strings/comments
  before keywords, and a hard invariant test: stripping SGR from highlighted rows
  reproduces the plain render byte for byte.
- [Fuzzy matching changes which command `/m` selects] → ranking is deterministic
  (prefix > interior, ties by declaration order) and covered by table-driven tests;
  `/m` still resolves to `/model`.
- [Tab completion changes Tab from inert to active outside the palette] → completion
  never inserts Tab and is config-gated (`ui.path_completion = false`); no candidate is
  offered outside the workspace.
- [New palette modes touch mouse hit-testing and `mouse_wants` state] → all modes go
  through the single palette renderer/mouse branch, covered by the existing palette
  tests plus a path-mode click test.
- [This delta restates `config`'s Defaults requirement from an uncommitted revision
  of `openspec/specs/config/spec.md`, and tasks 1.x/5.4/9.x lean on seams
  (`run_ui_with(..., sink)`, `paint`) that live in uncommitted working-tree changes] →
  commit the existing work before implementing or archiving this change; if that is
  not possible, re-derive the Defaults restatement and the frame-capture seam from
  whatever is on disk at that moment.
- [Pre-existing spec drift, found while writing this delta: `openspec/specs/tui` still
  required a `?` help overlay and "help content" in the palette, but M9 removed both
  from the code] → resolved in this change: the restated Palette requirement drops the
  stale "help content" mention, and the unimplemented `Help overlay` requirement is
  removed through a `## REMOVED Requirements` delta so `openspec archive` retires it
  from `openspec/specs/tui/spec.md` with the rest of the change.

## Migration Plan

- No data migration. Config keys are additive with behavior-preserving defaults except
  that `ui.highlight = "auto"` colors code blocks and `ui.turn_separators = true` adds
  separator rows; both are one-line opt-outs.
- Rollback is `git revert` of the implementation commit: artifacts are additive, the
  config keys are ignored when the code does not read them, and no on-disk
  session/config format changes.
- Ship order inside the change: (1) entry model + height index + parity harness,
  (2) separators and the in-transcript marker on top of the model, (3) palette
  refactor, (4) completion, (5) copy targets + toast, (6) highlighting,
  (7) live-turn-feedback coverage (task group 9 — independent, it only locks down
  behavior that already ships), (8) docs and the full-suite gate.

## Open Questions

- Should `ui.highlight = "on"` override `NO_COLOR=1`? This change treats `NO_COLOR`,
  ASCII mode and the `mono` theme as absolute (they win over `"on"`), consistent with
  the existing ASCII/theme precedence; revisit if users ask for a forced-color escape
  hatch. (Raised during review and deliberately left as-is; it affects only which one
  of two documented precedence rules wins, not the approach or the task breakdown.)
