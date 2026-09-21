# Proposal: pretty-transcript-rendering

## Why

Tool calls already collapse to one line, but the collapsed row carries almost no
signal and the expanded body carries too much: a failure has no first-error line
of its own (the whole error body is dumped into the transcript), `read` bodies are
unhighlighted even though the assistant's fenced blocks are already highlighted,
`write`/`patch` report counts instead of the change, and nothing shows what a
write will do before it happens. The reference implementation
(`pify/pretty`, a pi extension) solves exactly this class of problem: one-line
summaries that expand on demand, syntax-highlighted bodies, colourised diffs with
word-level emphasis, and a read-only projection of a pending change. This change
adopts that rendering model inside tether's existing collapse machinery.

## What Changes

- **Status glyph and always-visible failure line.** A tool row leads with `✓`
  (success) or `✗` (failure) instead of the current generic `⚙`; a failed call
  appends its first error line in the error role, clipped to the same width
  budget as any other summary, so the row never wraps and a failure is visible
  without expanding. The full error body moves behind expansion.
- **Display sanitization of tool output.** Everything but SGR colour is stripped
  before captured output reaches a transcript row (cursor moves, erase-line,
  carriage returns, window-title and other OSC escapes), and runs of blank lines
  collapse. This is display-only: the body the model receives is untouched.
- **Per-entry expansion.** A left click on a tool row toggles that entry, and
  `Ctrl+O` toggles the newest tool entry visible in the viewport; `Ctrl+Shift+O`
  keeps today's expand-all/collapse-all toggle on terminals that report the Shift
  modifier. On plain terminals (no keyboard protocol) `Ctrl+O` keeps its current
  expand-all meaning, so no capability is lost.
- **Highlighted tool bodies.** Expanded bodies are syntax-highlighted with the
  existing highlighter and theme roles, keyed to the call's own path instead of a
  markdown fence: `read` by the file extension, `grep` per matched path, with the
  `lineno<TAB>` prefix and `path:line:` prefix kept out of the colouring.
- **Results as diffs.** `write` and `patch` results render as a unified diff
  (syntax-highlighted body, old/new line numbers, `+N −M` with a proportional
  meter) instead of the bare count summary. The applied diff is also the body the
  model receives, preserving the existing "same text the UI offers when expanded"
  contract.
- **Word-level emphasis.** A removed line and the added line that replaced it are
  compared word by word and the carried-over words are muted, under conservative
  pairing: only same-length replaced runs are paired, a pair with too little in
  common is left alone, and pure insertions/deletions stay whole.
- **Pre-execution preview.** While a `write` or `patch` call is pending, the
  projected diff is rendered from the call arguments, read-only and bounded
  (target inside the workspace, at most 1 MiB, no writes); when the projection is
  unavailable the row falls back to the plain summary.

No new configuration keys: every part follows the existing `ui.highlight`,
`ui.ascii`/`NO_COLOR` and theme gates, and the diff overlay (§6.11 of
`docs/design.md`) keeps its current behaviour.

## Capabilities

### New Capabilities
- None. The rendering belongs to `tui`; the event payloads and the write/patch
  result bodies belong to `agent-core`.

### Modified Capabilities
- `tui`: tool rows gain a status glyph, a clipped first error line, per-entry
  expansion, display sanitization of bodies, path-keyed syntax highlighting of
  tool bodies, unified-diff rendering for write/patch with line numbers, word
  pairing and a diff meter, and the pending-change preview.
- `agent-core`: `tool_call_start` carries the parsed arguments and, for `write`
  and `patch`, an optional read-only projected diff; the `write` and `patch` tool
  bodies become the applied unified diff (so the model-facing body and the
  expanded UI body stay the same text) and the `write` summary becomes `+N −M`
  with a created/overwritten distinction.

## Impact

- Code: `src/tether/ui.lua` (tool entry model, `render_entry`, highlighting
  entry points, diff rendering, key/mouse dispatch, layout height), a new pure-Lua
  diff module for hunk generation and word pairing, `src/tether/agent.lua`
  (`tool_call_start` payload, write/patch bodies and summary, read-only preview).
- Tests: `tests/lua_tests.lua` — tool row rendering, per-entry toggle,
  sanitization, highlighting, diff rendering/word pairing, preview payload, and
  the existing height/virtualization invariants; `make test` must stay green.
- Docs: `README.md`, `docs/design.md` §6.3, §6.5, §6.11 and §6.13 (glyph,
  expansion keys, diff rendering), `docs/tech-spec.md`.
- No config, session-journal, provider or wire-format change; the result the model
  sees is unchanged apart from the `write`/`patch` body now being the applied diff.
