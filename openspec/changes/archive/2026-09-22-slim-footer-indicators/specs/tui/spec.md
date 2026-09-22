# Spec Delta

## MODIFIED Requirements

### Requirement: Screen regions
The TUI SHALL lay out: an optional header (disabled by default),
the scrollable transcript region, and a bottom dock holding the
input box, the optional palette, and the footer. With
`ui.alt_screen = true` the TUI SHALL enter the alternate screen
buffer on start and leave it on exit; with `false` the native
scrollback is kept.

Rows SHALL be allocated bottom-up: the dock rows are reserved from
the bottom of the screen (see the footer requirement for the exact
budget) and the transcript receives every remaining row. No
region SHALL overlap another, and a change in dock height SHALL
change the transcript height by the same number of rows.

Within the dock the rows SHALL run, top to bottom: the input box's
top rule, the input's content rows, its bottom rule, the palette rows
(only while the palette is open), and the footer's single row.

#### Scenario: alt_screen default
- **WHEN** the user starts the TUI without config
- **THEN** the alternate screen buffer is used

#### Scenario: Dock order
- **WHEN** a frame is rendered with a one-line input and a closed palette
- **THEN** the box's two rules and the footer's single row are the last three rows of the screen, in that order, with no other region between them

### Requirement: Scroll position indicator
When the user scrolled up, the TUI SHALL report how many transcript
rows are hidden below as `↓ +N` (ASCII `v +N`) on the footer's single
row while following is off. Returning to the bottom SHALL re-enter
follow mode and remove the indicator. No marker SHALL be painted
inside the transcript. The indicator SHALL be omitted when the count
is zero. The reported count SHALL stay exact across appends,
expansion toggles, `/clear`, `/new`, and resize.

#### Scenario: Indicator while scrolled up
- **WHEN** the transcript is scrolled up with lines below
- **THEN** the footer shows `↓ +N` with the count and no transcript row carries a scroll marker

#### Scenario: In-transcript marker
- **WHEN** the user scrolled up and 7 transcript rows are hidden below
- **THEN** no transcript row ends with a scroll marker; only the footer shows `↓ +7`

#### Scenario: Marker hidden at the bottom
- **WHEN** the user is in follow mode at the bottom of the transcript
- **THEN** the footer does not show the scroll indicator

#### Scenario: ASCII mode renders the marker in ASCII
- **WHEN** ASCII mode is active and the transcript is scrolled up
- **THEN** the footer indicator renders as `v +N` with no non-ASCII glyphs

#### Scenario: No room for the marker
- **WHEN** the footer row is too narrow to hold the scroll indicator beside the left content
- **THEN** the indicator is omitted or truncated per the footer truncation order and the row content is rendered intact

#### Scenario: Count survives expansion
- **WHEN** the user is scrolled up, expands all tool results, and stays scrolled up
- **THEN** the reported hidden-row count equals the difference between the new transcript height and the viewport bottom

### Requirement: Footer
The TUI SHALL render the footer as a single dim row below the input
box and SHALL NOT use a reverse-video row for it. The footer SHALL
occupy exactly one row regardless of active indicators.

That row SHALL carry, left to right: the workspace path with a
leading `$HOME` abbreviated to `~`; on the left side joined by a
single space the session's accumulated input tokens as `↑<count>`,
its accumulated output tokens as `↓<count>` (each omitted while
zero), and the context cell `used/max (pct%)`; any active transient
flags joined by a single space (the one-shot toast and the scroll
indicator only — no mouse-mode or keyboard-protocol icons); and the
model name right-aligned on the same row, at least two columns away
from the left side. Counts SHALL use the compact form: plain below
1000, one decimal with `k` below 10000, a rounded `k` below 1000000,
and `M` above. The model name SHALL end in the row's last column
whenever both sides fit; when they cannot both fit, the model name
SHALL be truncated from its left so its tail survives, and dropped
entirely only when nothing of it fits. When the left content alone
exceeds the available width, SHALL truncate in this order: path from
the right with a dim `...`, then transient flags dropped (toast
before the scroll indicator), then the left stats side from the
right with a dim `...`.

The footer's row SHALL be counted in display columns: wide
East-Asian characters count as 2 and ANSI sequences as 0. In ASCII
mode the token and scroll arrows SHALL render as `^` and `v`, and no
non-ASCII glyph SHALL be introduced by the footer.

#### Scenario: Idle footer
- **WHEN** no turn is running, no flag is active, and the session has used 3000 input and 1000 output tokens
- **THEN** the single footer row starts with the `~`-abbreviated workspace followed by `↑3.0k ↓1.0k` and the context cell, and ends with the model name

#### Scenario: Model is right-aligned
- **WHEN** the model name fits beside the left side
- **THEN** it ends in the last column of the footer row and at least two blank columns separate it from the left side

#### Scenario: Counters accumulate across turns
- **WHEN** one turn reports 1200 prompt and 300 completion tokens and a later turn reports 800 and 200
- **THEN** the counters read `↑2.0k` and `↓500`

#### Scenario: Context cell keeps its thresholds
- **WHEN** token usage reaches `ui.summarize_at`
- **THEN** the context cell is rendered as a warning, and at 90% or more as an error

#### Scenario: Toast and scroll share the footer row
- **WHEN** a one-shot toast is active and the transcript is scrolled up
- **THEN** the footer's single row carries both the toast and `↓ +N` separated by one space (no second or third footer row is painted), and each disappears when it expires or returns to the bottom

#### Scenario: No reverse video
- **WHEN** the footer row is rendered
- **THEN** no footer row uses reverse video and the row is dim

#### Scenario: Narrow terminal drops the model name
- **WHEN** the model name cannot fit beside the left side of the footer
- **THEN** the left side is rendered intact and the model name is truncated from its left, or omitted if nothing of it fits

#### Scenario: ASCII mode
- **WHEN** ASCII mode is active and counters are shown
- **THEN** the arrows render as `^` and `v` and the footer introduces no non-ASCII glyph
