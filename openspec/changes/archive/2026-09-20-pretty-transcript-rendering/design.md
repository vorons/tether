# Design

## Context

See `proposal.md` — Why. The pieces that shape the approach:

- **Transcript entries.** A tool call becomes a normal transcript entry
  (`{role="tool", id, name, status, summary, body, collapse_lines}`) appended on
  `tool_call_start` and filled in on `tool_result`; `render_entry` in
  `src/tether/ui.lua` is the single renderer, and the virtualized height index
  (`entry_height`/`touch_entry`/`invalidate_all`) requires any entry-shape change
  to bump the entry's `ver` and invalidate the index from that point.
- **Body text.** `agent.tool_body` builds the expanded body per tool; the same
  text goes into the model's history. `read` bodies are `lineno<TAB>content`,
  `grep` bodies are `path:line: text` rows.
- **Highlighting.** `ui.tokenize_line` / `ui.highlight_line(line, lang, state)`
  already colour Lua/C/sh/python/js/go/rust/json with theme roles, and
  `md_render` uses them for fenced blocks, carrying tokenizer state across the
  block. The gates are `ui.highlight`, `highlight_enabled()`, `ui.ascii` and the
  `sgr_role` theme table (`mono` emits nothing).
- **Diff text.** `patch` arguments already carry a unified diff and the tool
  applies it strictly or refuses, leaving the file untouched.
- **Input.** `read_key` decodes kitty CSI-u and modifyOtherKeys into
  `{kind="ctrl", code, shift}` records (that is how `Ctrl+Shift+C` already
  works); plain terminals report no modifier, so `Ctrl+Shift+<key>` is
  indistinguishable from `Ctrl+<key>` there. The mouse state machine
  (`M.mouse_wants`) enables SGR reporting only for `ui.mouse = "on"` or an open
  menu/palette.
- **Constraints.** All logic stays in Lua inside the single binary, no external
  process, tests are pure-Lua frame/unit tests in `tests/lua_tests.lua`, and the
  proposal rules out new config keys.

## Goals / Non-Goals

**Goals**

- One renderer change that makes collapsed rows informative and expanded rows
  readable, with the diff as the central artifact (projection, result, emphasis).
- Keep the existing collapse caps, virtualization/height invariants, ASCII and
  colour gates, and the "expanded body is the same text the model got" contract.
- Everything testable from the existing Lua harness: the diff engine, the
  sanitizer, the panel-state model and the frame output.

**Non-Goals**

- Side-by-side (split) diff rendering and a configurable detail tier.
- A transcript focus cursor, per-tool renderer opt-out keys, or persisting
  expansion state across sessions.
- Verifying a pending `patch` against the file (in-memory application) — see
  Decision 3.
- Changing the diff overlay (§6.11) beyond reusing the renderer's parsing.
- Any provider, session-journal or wire-format change.

## Decisions

### 1. Diff logic lives in a new pure-Lua module

`src/tether/diff.lua` provides three things and nothing else:

- `unified(old_text, new_text)` → unified diff text plus `{add, del}` counts
  (line-level LCS, grouped into hunks with context).
- `parse(diff_text)` → rows for rendering: per row the kind
  (context/add/remove/hunk-header/no-newline), the old and new line numbers and
  the text; built from the `@@ -a,b +c,d @@` headers.
- `pair_words(removed_row, added_row)` → emphasised segments for the word-level
  emphasis rules (see Decision 6).

Rationale: the agent needs hunk generation for the projection, the UI needs
parsing and pairing for rendering, and both must be unit-testable without a
terminal. Alternatives considered: putting it in `ui.lua` (the agent would end up
depending on the UI module — wrong direction, and `ui.lua` is already the largest
file), shelling out to `diff` (violates the no-external-CLI constraint), or
re-deriving hunks inside the UI (duplicate logic that can disagree with the
projection).

### 2. The projection is computed by the agent and sent with `tool_call_start`

The agent already resolves paths and applies workspace policy through `tools`,
so it computes the projection (target path, kind, diff text, counts) before the
call runs and attaches it to the `tool_call_start` payload together with the
parsed arguments. The UI never touches the filesystem.

The projection is bounded and side-effect free: resolve with symlinks, require
the target inside the workspace, read at most the documented bound (1 MiB, the
same bound `read` uses), never write, never touch history or the journal. Any
failure omits the projection but never the call. Alternatives considered: the UI
reading the file itself (`io.open` in `ui.lua` — duplicates containment policy
and breaks the layering), or deferring projection until the confirmation menu
opens (the preview would be missing for auto-approved calls, and the menu body
already renders the raw patch without line numbers or colours).

### 3. A pending `patch` previews the submitted diff; it is not re-applied

For `patch` the projection is the submitted diff text (parsed for counts and
line numbers). `tools.patch` applies strictly — either every hunk matches or the
file is untouched — so the submitted diff and the applied diff agree on success,
and on conflict the call reports the conflict in its error result. pretty goes
further and mirrors the editor's own application in memory before showing a
preview; tether's strict-patch contract makes that redundant, and matching hunks
in the preview would duplicate `tools.patch`'s applier. Accepted consequence: a
patch that will conflict still previews the requested change; the row is visibly
pending and the failure surfaces as the error row.

### 4. `write` and `patch` result bodies become the applied diff

The body is what the model receives, so writing the diff there keeps the
existing agent-core invariant that the expanded body and the model's content are
the same text, and lets the UI render a diff without a second payload on
`tool_result`. The projection read at step 2 supplies the previous content, so
there is no second file read. `write` gains a summary of `+N −M` plus a
created/overwritten word; its body stops being a bare path.

Trade-off: the model now sees diffs instead of a path, which costs context — the
existing `TOOL_BODY_MAX` (16 KB) truncation still bounds it. Alternative
considered: keep the body as the path and add a UI-only `diff` field (no extra
model context, but the agent-core invariant breaks and the UI needs the previous
content again anyway).

### 5. Expansion is per-entry state plus an inherited all-entries state

Each entry gets an explicit per-entry state (`expanded` / `collapsed`) or
inherits the all-entries flag, which defaults to collapsed. `Ctrl+O` sets the
entry's explicit state to the opposite of its current *effective* state.
`Ctrl+Shift+O` flips the all-entries flag and clears every per-entry state, so
the all-toggle is a predictable reset. Where the terminal cannot report the Shift
modifier, `Ctrl+O` keeps the all-entries meaning — the same fallback shape the
project already uses for `Shift+Enter`.

`Ctrl+O` targets the newest tool entry whose rows overlap the viewport, falling
back to the newest entry overall, so the key acts on what is on screen. A left
click toggles the entry under the pointer where the mouse mode delivers
transcript clicks (`ui.mouse = "on"`); `auto` keeps its promise of native text
selection, so no transcript click arrives there. Alternatives considered: a
transcript focus cursor (↑/↓ already scroll or move the input cursor — a new
mode is a much larger change), toggling the newest entry regardless of scroll
(acts on something the user cannot see), and dropping expand-all (loses an
existing capability).

### 6. Word emphasis: conservative pairing, no backgrounds

Adjacent removed/added runs are paired only at equal length; the pair is dropped
when the lines share too little content (a similarity threshold over the common
segments), and lines beyond a documented column threshold skip comparison
entirely because the comparison is quadratic. Changed words keep the
added/removed role and carried-over words take the muted `dim` role; there is no
reverse video or background because tether's theme roles carry no backgrounds —
this is the deliberate divergence from pretty, which uses the theme's diff
backgrounds. A colour-free theme renders the diff without emphasis rather than
emitting a bare style.

### 7. Sanitization and highlighting are pure row transforms

`sanitize_output(text)` strips everything but SGR (cursor movement, erase-line,
carriage returns, OSC/DCS such as window-title changes), collapses blank-line
runs and is applied at render time only — the stored body and the model's copy
stay raw. SGR is kept while colour is on and stripped entirely when it is off
(ASCII, `NO_COLOR`, `mono`), matching the project's existing gates rather than
pretty's always-keep-SGR rule.

Highlighting is keyed by path: a shared extension→language map (`.lua`→lua,
`.c`/`.h`→c, `.sh`/`.bash`→sh, `.py`→python, `.js`/`.ts`→js, `.go`→go, `.rs`→rust,
`.json`→json) rather than a markdown fence. One tokenizer state spans the whole
body, matching `md_render`; the `lineno<TAB>` prefix (read) and `path:line: `
prefix (grep) are rendered outside the coloured span, so removing SGR reproduces
the plain rows exactly. `list`, `glob` and `run` bodies stay unhighlighted.

### 8. Rendering stays inside the existing virtualized entry model

The diff renderer, the word-emphasis segments and the status row are produced by
`render_entry` as plain rows, so the height index, the scroll indicator and the
`_render_all` parity helper keep working unchanged. Toggles call `touch_entry`
(path-keyed cache) and `invalidate_all` only for the all-entries case, so height
and the hidden-row count stay exact. Cached rows stay bounded by the existing
cache limit; a large diff is re-rendered per repaint rather than pinning the
cache, as a large body already is.

### 9. Row layout

Tool row: `<marker> <name>  <summary>`, where the marker is `✓`/`✗`/pending
(ASCII `[ok]`/`[x]`/`…`), the summary is the existing per-tool text plus the diff
meter for write/patch, and a failure appends the clipped first error line.
Diff rows: a right-aligned old/new gutter (the old number on removed lines, the
new number on added lines, both on context), then the kind marker, then the
content; ASCII keeps the same layout with `+`/`-`/` ` and `#` for the meter.

## Risks / Trade-offs

- **Height/scroll drift after toggles** → toggles go through `touch_entry` and
  bump `ver`; tests assert exact heights and hidden-row counts for per-entry and
  all-entry toggles.
- **A synchronous file read on the turn path** (the projection) → only for
  `write`/`patch`, only inside the workspace, capped at 1 MiB, and a failure
  omits the projection instead of failing the call.
- **More model context for write/patch** → the diff body is bounded by the
  existing 16 KB truncation; the fallback path restores the old body when the
  previous content is unreadable.
- **Quadratic word comparison on minified lines** → column threshold skips
  comparison; the per-row work stays proportional to the visible diff.
- **`Ctrl+Shift+O` unavailable on plain terminals, transcript clicks unavailable
  under `ui.mouse = "auto"`** → plain terminals keep `Ctrl+O` = expand-all, and
  the click path is documented as requiring `ui.mouse = "on"`; per-entry toggling
  is then reached with `Ctrl+O`.
- **Foreign SGR in captured output clashing with the theme** → stripped whenever
  colour is off, and the wrap/width helpers already treat SGR as zero-width.
- **A previewed patch that later conflicts** → the row stays pending and the
  conflict appears as the error row; the divergence from pretty is documented in
  Decision 3.

## Migration Plan

No persisted state, config key, journal field or wire format changes, so there is
nothing to migrate: existing sessions, config files and `auto_approve` files keep
working, and reverting the change restores the previous rendering (the only
durable difference is that `write`/`patch` bodies in new sessions are diffs).
Rollout is a normal build: `make test` must pass (Lua unit and frame tests, host
smoke, host primitives) with `README.md`, `docs/design.md` (§6.3, §6.5, §6.11,
§6.13) and `docs/tech-spec.md` updated in the same change.

## Open Questions

- The numeric knobs — the word-diff column threshold, the similarity threshold,
  the meter's block count and the preview read bound — are tuning values that
  change no requirement and can be adjusted later without touching the specs.
- Whether the `write`/`patch` diff body stays the model-facing body long-term
  (Decision 4) is worth revisiting once real sessions show its context cost; a
  later change could keep the body as the diff for the UI and send the path to
  the model without affecting this change's rendering rules.
