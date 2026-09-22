# Proposal

## Why

The footer currently wastes three rows (path, stats, optional flags) on a mostly static status line, while the scroll indicator is duplicated inside the transcript and permanent mouse/keyboard mode icons add noise that almost never changes mid-session. Collapsing to one footer row reclaims vertical space for the transcript and keeps only indicators that still matter.

## What Changes

- **BREAKING**: the footer shrinks from three rows (path row + stats row + optional flag row) to a single row that combines workspace path, token/context stats, model name, and any active transient flags (toast, scroll indicator) with defined truncation priority.
- Remove the in-transcript `↓ +N` (ASCII `v +N`) scroll marker from the newest visible transcript row; the footer remains the sole scroll-position indicator.
- Remove the mouse-mode (`🖱 <mode>`) and keyboard-protocol (`⌨ kitty` / `⌨ xterm`) icons from the footer; toast and scroll indicator persist as transient content on the single footer row.
- Update layout budget, tests, and living docs to match the one-row footer and marker removal.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `tui`: "Screen regions" dock order no longer lists a separate path/stats/flag row stack; "Scroll position indicator" drops the in-transcript marker and keeps only the footer indicator; "Footer" becomes a single combined row and drops mouse/keyboard mode flags.

## Impact

- Code: `src/tether/ui.lua` (`layout`, `render_footer`, `static_flags`, `scroll_flag`, in-transcript marker paint, mouse flag arming)
- Tests: `tests/lua_tests.lua` (T65, T92–T95, pi 2.2, pi 5.3)
- Docs: `README.md`, `docs/tech-spec.md`, `docs/design.md`
- No API, dependency, or session-format changes
