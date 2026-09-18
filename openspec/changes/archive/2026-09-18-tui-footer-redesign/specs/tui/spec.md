# Spec Delta

## ADDED Requirements

### Requirement: Footer separator
The TUI SHALL render a single dim `─`-filled separator row between the
input field and the status line. The separator SHALL be owned by the
layout computation so it stays exact across input-height changes,
palette visibility, error-banner visibility, and terminal resizes.
The separator SHALL be dim in every theme, including `mono` (it is a
static glyph row, not a colored role). In ASCII mode the separator
SHALL use `─` replaced by `-`.

#### Scenario: Separator sits between input and status
- **WHEN** the TUI renders a normal frame with a non-empty or empty input
- **THEN** the row directly above the status line is a dim rule
  spanning the terminal width

#### Scenario: Separator survives resize and input height change
- **WHEN** the terminal is resized or `ui.input_max_lines` grows the input
- **THEN** the separator remains a single row between input and status,
  and the status line still occupies the last row of the screen

#### Scenario: Separator in ASCII mode
- **WHEN** ASCII mode is active
- **THEN** the separator uses ASCII `-` instead of `─`

## MODIFIED Requirements

### Requirement: Token usage in status line
The status line SHALL consist of a small fixed set of mandatory parts
rendered in this order, joined by ` · `:
1. `spinner Ns` — only while a turn is busy
2. `model` — the active model name
3. `workspace` — the current workspace path (`~`-abbreviated)
4. `token usage` — `used/max (pct%)` with a `≈` prefix when estimated

Additional flags SHALL NOT be visible by default; they appear only
while relevant:
- `🖱 <mode>` — visible for a short window after the mouse mode
  actually changes, then fades.
- `⌨ <proto>` — visible only when a keyboard protocol is detected
  (non-zero).
- `↓ +N` / `v +N` — the scroll indicator, visible while the user is
  scrolled up.
- The one-shot toast (e.g. `✓ скопировано`) — leads the line while
  active and is cleared by the next keypress.

The status line SHALL stay on a single row; when mandatory parts exceed
the width, overflow SHALL be truncated from the right.

#### Scenario: Default idle line
- **WHEN** no turn is running, no flags are active, and the user is at
  the bottom of the transcript
- **THEN** the status line is `model · ~/workspace · used/max (pct%)`
  with no `🖱`, no `⌨`, no scroll indicator, and no spinner

#### Scenario: Busy turn leads with spinner
- **WHEN** a turn is running and 3 seconds have elapsed
- **THEN** the first part is `spinner 3s` followed by model, workspace,
  and token usage

#### Scenario: Mouse mode shown briefly after change
- **WHEN** the effective mouse mode switches from `auto` to `off`
- **THEN** `🖱 off` is visible in the status line for a few seconds and
  then disappears

#### Scenario: Keyboard protocol shown only when detected
- **WHEN** the TUI negotiated the Kitty keyboard protocol
- **THEN** `⌨ kitty` is visible; when no protocol was detected the
  part is absent

#### Scenario: Summary threshold shown
- **WHEN** token usage reaches `ui.summarize_at`
- **THEN** the status line shows the percentage as a warning

### Requirement: Scroll position indicator
When the user scrolled up, the TUI SHALL report how many transcript
rows are hidden below as `↓ +N` (ASCII `v +N`). The status line SHALL
show the count, and the newest visible transcript row SHALL
additionally carry the same marker, right-aligned, while following is
off. Returning to the bottom SHALL re-enter follow mode and remove
both indicators. The in-transcript marker SHALL be omitted when the
count is zero, when the row is too narrow to hold it without
truncating the row's own content, and while an overlay is open. The
reported count SHALL stay exact across appends, expansion toggles,
`/clear`, `/new`, and resize.

#### Scenario: Indicator while scrolled up
- **WHEN** the transcript is scrolled up with lines below
- **THEN** the status line shows `↓ +N` with the count

#### Scenario: In-transcript marker
- **WHEN** the user scrolled up and 7 transcript rows are hidden below
- **THEN** the newest visible transcript row ends with `↓ +7` and the status line shows the same count

#### Scenario: Marker hidden at the bottom
- **WHEN** the user is in follow mode at the bottom of the transcript
- **THEN** neither the transcript row nor the status line shows the marker

#### Scenario: ASCII mode renders the marker in ASCII
- **WHEN** ASCII mode is active and the transcript is scrolled up
- **THEN** the marker renders as `v +N` with no non-ASCII glyphs

#### Scenario: No room for the marker
- **WHEN** the newest visible row is too narrow to hold the marker
- **THEN** the marker is omitted and the row content is rendered intact

#### Scenario: Count survives expansion
- **WHEN** the user is scrolled up, expands all tool results, and stays scrolled up
- **THEN** the reported hidden-row count equals the difference between the new transcript height and the viewport bottom
