# Proposal

## Why

The TUI works, but it stops carrying its weight once a session gets long or busy.
Three friction clusters show up repeatedly: there is no way to see *where* you are
in a transcript (the "new messages below" count lives only in the status line, and
nothing separates one turn from the next), input is manual (no path completion, and
copy is limited to the last assistant answer), and rendering does not scale (code
blocks are monochrome even though the fence language is already parsed, and the
transcript caches every wrapped line of the whole session in memory and re-renders
it on every repaint). Fixing these together is one coherent change: they all touch
the transcript/input rendering path in `src/tether/ui.lua`.

## What Changes

**Navigation and readability (M)**

- **In-transcript "new below" indicator**: when the user has scrolled away from the
  bottom, the newest visible transcript row carries a right-aligned `↓ новые +N`
  marker (ASCII `v новые +N`), in addition to the existing status-line field.
- **Turn separators**: each new user turn is preceded by a dim separator row
  `── 14:32 ──` (ASCII `-- 14:32 --`), making turn boundaries visible. Toggleable
  with `ui.turn_separators` (default true).

**Input and diagnostics (M/L)**

- **Path completion**: `Tab` outside the palette completes the token under the
  cursor against workspace paths, opening the palette with the candidates
  (directories get a trailing `/`). Repeating `Tab` cycles candidates; `Esc` closes.
  Toggleable with `ui.path_completion` (default true).
- **Wider copy**: a `/copy` palette lists copy targets newest-first — last answer,
  last tool output, last code block, whole transcript — with byte sizes; `Enter`
  copies the selected target through the existing OSC 52 path. `Ctrl+Shift+C`
  keeps copying the last answer directly. A transient `✓ скопировано <size>` toast
  confirms.
- **Dynamic palette**: matching changes from prefix-only to fuzzy (subsequence,
  scored), the selected item shows its description, and the command list grows
  (`/copy`, `/skills`).
- **Skills in the palette**: discovered skills are listed as palette entries;
  selecting one appends a reference to the skill and its `SKILL.md` path to the
  input buffer without loading the body.

**Rendering scale (L)**

- **Syntax highlighting**: fenced code blocks are colored from the fence language
  (lua, c, sh, python, js/ts, go, rust, json; unknown language stays dim). Color
  depth is negotiated at startup (truecolor when `COLORTERM` advertises it, else
  256-color, else 16-color) and degrades to no color in ASCII/`mono`/`NO_COLOR`.
  Toggleable with `ui.highlight` (`"auto"` | `"on"` | `"off"`, default `"auto"`).
- **Transcript virtualization**: rendering cost and memory become proportional to
  the viewport instead of the session — wrapped lines are cached per entry and
  evicted, and the transcript height/index is maintained incrementally so the
  scroll indicator and scrollbar math stay O(1).

**Turn feedback (documentation and coverage)**

- The live turn feedback already present in the working tree — repaint during a
  synchronous turn, the `✻ tether думает…` placeholder, the `▌` streaming caret, and the
  spinner with elapsed time in the status line — is brought under this change: it gains
  a requirement and tests instead of new implementation, so it stops being an
  undocumented side effect.

**Requirement cleanup**

- The stale `Help overlay` requirement in `openspec/specs/tui` (a `?` keybinding
  overlay that the code has not implemented since M9) is removed, so the spec stops
  describing behavior the TUI does not have.

## Capabilities

### New Capabilities

None — every behavior here extends the existing interactive UI capability.

### Modified Capabilities

- `tui`: adds requirements for turn separators, path completion, copy targets,
  palette skill entries, code-block syntax highlighting,
  viewport-proportional transcript rendering, and live turn feedback (documenting
  behavior that is already implemented); restates the scroll-position
  indicator (the count moves into the transcript as well as the status line) and
  the palette (fuzzy matching, wider command set, descriptions, and Enter
  applying a command only when something matches); removes the unimplemented
  `Help overlay` requirement.
- `config`: the `ui` defaults gain `highlight = "auto"`, `turn_separators = true`,
  and `path_completion = true`; the Defaults requirement is restated with them.

## Impact

- `src/tether/ui.lua` — transcript entry model and render path (separators,
  indicator, virtualization), input model (completion, palette), copy path (targets
  + toast), markdown code-block renderer (highlighting).
- `src/tether/config.lua` — three new `ui` defaults.
- `src/tether/tools.lua` — read-only reuse of the workspace listing (`list`) for
  completion candidates; no behavior change to the tool contract.
- `src/tether/context.lua` — read-only reuse of `discover_skills` for palette
  entries; no change to prompt composition.
- `tests/lua_tests.lua` — new coverage for completion, fuzzy matching, copy target
  selection, separators, indicator, highlighting rules, virtualization bounds, and the
  live-turn-feedback lifecycle; existing render assertions may need updating because
  separators add rows.
- Docs: `README.md` (TUI features), `docs/design.md` §6 (regions, transcript
  blocks, palette, markdown-lite, new config keys).
- No C host changes, no new runtime dependencies, no network or provider impact.
