# Spec Delta: tui

## MODIFIED Requirements

### Requirement: Session lists are palette modes

`/resume` SHALL open the shared palette with `palette_mode = "resume"` and items from the session listing (never a full-screen overlay). Enter SHALL resume the selected session, replace the visible transcript via transcript seed, and append a resumed-session marker; Esc SHALL close the palette with no side effects; arrows and mouse selection SHALL behave as for `/copy`. `/model` SHALL open the shared palette with `palette_mode = "model"` and items from the model listing; Enter SHALL set `S.model_name` (and `S.cfg.model`), persist the pick into `~/.tether/config.lua` per the config model-persistence requirement, and append a `→ модель: …` system row; Esc SHALL close without changing the model. Neither mode SHALL set `S.overlay`.

#### Scenario: Resume opens a palette
- **WHEN** the user runs `/resume` with at least one session on disk
- **THEN** `palette_mode` is `resume`, the palette is active, items are non-empty, and no overlay is open

#### Scenario: Resume Enter picks a session
- **WHEN** the resume palette is open and the user presses Enter on a session
- **THEN** the palette closes, `S.session_id` updates, and the transcript is replaced with the picked session plus a marker

#### Scenario: Resume Esc is a no-op
- **WHEN** the resume palette is open and the user presses Esc
- **THEN** the palette closes and no session is resumed

#### Scenario: Model opens a palette
- **WHEN** the user runs `/model`
- **THEN** `palette_mode` is `model`, the palette is active with model items, and no overlay is open

#### Scenario: Model Enter changes the model
- **WHEN** the model palette is open and the user presses Enter on a model
- **THEN** `S.model_name` is that model, a system row `→ модель: …` is appended, and `~/.tether/config.lua` holds the picked `provider`/`model` afterwards

#### Scenario: Model Esc does not change the model
- **WHEN** the model palette is open and the user presses Esc
- **THEN** `S.model_name` is unchanged and the palette closes
