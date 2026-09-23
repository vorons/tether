# Tasks

## 1. Strip overlay backends

- [x] T1: error → banner + debug-log only (R4)
- [x] T2: confirmation without details / `[d]` / digit `6` (R3/R6)
- [x] T3: delete diff overlay (R3)
- [x] T4: `/resume` → `palette_mode = "resume"` (R2)
- [x] T5: `/model` → `palette_mode = "model"` (R2)
- [x] T6: login secret → masked input buffer + no overlay (R5)

## 2. Delete infra

- [x] T7: remove `S.overlay` / `render_overlay` / `handle_overlay_key` /
  `overlay_full` / `M._set_overlay` and all `if S.overlay` gates (R1)

## 3. Acceptance

- [x] T8: `make test` green; no dead overlay/details symbols in `src/tether`;
  KEYMAP/footer without details/overlay
- [x] T9: docs sync (`README.md`, `docs/design.md`, `docs/tech-spec.md`) +
  this openspec change; `openspec validate remove-overlay-ui`
