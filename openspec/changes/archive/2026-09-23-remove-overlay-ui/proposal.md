# Proposal

## Why

`ui.lua` runs two parallel modal systems: the palette (dropdown under the
input) and full-screen overlays (`resume`, `model`, `diff`, `error`, login
dialog). Key-handling, `sel`/`items` and Esc-close are duplicated. Product
decisions: the `diff` and `error` overlays are not needed; `resume`/`model`
are lists the palette already renders.

## What Changes

- **Delete overlay infrastructure**: `S.overlay`, `S.overlay_data`,
  `render_overlay`, `overlay_full`, `handle_overlay_key`, `M._set_overlay`,
  and every `if S.overlay` gate in `handle_key` / key-pump / mouse / caret.
- **Lists become palette modes**: `/resume` → `palette_mode = "resume"`,
  `/model` → `palette_mode = "model"` (same `_in_*_palette` pattern as
  `/copy` and the `/login` picker).
- **Remove confirmation `details`**: menu is
  allow / session / always / deny / cancel; digits `1..5`; no `[d]`, no
  `S.overlay = "diff"`. Projected diffs stay on pending tool-rows in the
  transcript; result bodies stay behind expand.
- **Error is a one-line banner + debug log**: Enter/Esc on the banner clears
  it (never opens a modal); full error text goes to the debug log when
  enabled, never to a transcript row.
- **Login secret is a masked input mode**: `S.login_secret = { buf }` is a
  dedicated buffer (never `S.input`); `render_input` paints `*`×len with a
  `login <provider>` label; text/paste/backspace → `buf`; Enter →
  `submit_login_secret`; Esc → `cancel_login`. The provider picker stays
  `palette_mode = "login"`.

## Capabilities

### New Capabilities

- none (refactor of existing TUI behavior; no new user-facing capability).

### Modified Capabilities

- `tui`:
  - Purpose and requirements no longer describe overlays as a mechanism.
  - Confirmation menu drops `details` / `[d]` / digit `6`.
  - "Error banner and overlay" becomes a banner-only requirement (Enter/Esc
    clear; no modal).
  - Live-turn feedback and caret gates reference palette / confirmation /
    ask / secret keyboard ownership instead of "overlay open".
  - Session lists (`/resume`, `/model`) are palette modes.
  - Input-field hardware-cursor note no longer mentions overlays.
- `provider-auth` (when that capability exists in main specs): credential
  entry is masked secret mode, not a dialog overlay.

## Impact

- Code: `src/tether/ui.lua` (main cut), `tests/lua_tests.lua` (T153–T160
  rewritten), no agent/API contract change.
- Docs: `README.md`, `docs/design.md` §6, `docs/tech-spec.md`.
- Risks: long errors lose full-text-in-chat (banner + debug-log is the
  accepted trade-off); resume/model UX moves from full-screen to dropdown
  (palette window scrolls); login secrets could leak into `S.input` if the
  buffer gate regresses (unit tests T153/T156 guard isolation).
- Out of scope: moving palette to `palette.lua`, confirm-policy changes,
  ask-block.
