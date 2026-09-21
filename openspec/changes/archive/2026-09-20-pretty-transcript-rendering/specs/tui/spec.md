# Spec Delta

## ADDED Requirements

### Requirement: Tool row status and failure visibility
Every tool call SHALL occupy a transcript row whose leading marker reports
its state: `✓` for a successful call (ASCII `[ok]`), `✗` for a failed one
(ASCII `[x]`), and the pending indicator while the call runs. The row SHALL
carry the one-line summary (result counts, exit code, change counts) after
the tool name.

A failed call SHALL additionally carry the **first line** of the error text
in the error role, on the same row as the summary, clipped to the same width
budget as any other summary so a long error message cannot make the row wrap
onto a second line. The full error text SHALL become visible through
expansion; while the row is collapsed no further error lines SHALL be
rendered. Failures SHALL be visible without expansion: a failure the user has
to expand to notice does not count as reported.

#### Scenario: Successful row leads with the done glyph
- **WHEN** a `read` call returns 214 lines
- **THEN** the row renders `✓ read` followed by the line-count summary and no error text

#### Scenario: Failure shows its first error line while collapsed
- **WHEN** a `run` call fails with a multi-line stderr and the terminal is 60 columns wide
- **THEN** the collapsed row occupies exactly one row, starts with `✗ run`, and contains the first error line clipped to the row width

#### Scenario: Remaining error lines wait for expansion
- **WHEN** the user expands a failed call whose error text has four lines
- **THEN** the full error text is rendered in the body

#### Scenario: ASCII mode renders the markers in ASCII
- **WHEN** ASCII mode is active and a tool call succeeds
- **THEN** the row starts with `[ok]` and no non-ASCII glyph for the marker

### Requirement: Tool output display sanitization
Before captured tool output is rendered into transcript rows, collapsed or
expanded, the TUI SHALL remove every control sequence except SGR colour
selection: cursor movement, erase-line and erase-screen, carriage returns,
and OSC/DCS sequences (including window-title changes) SHALL NOT reach the
screen. Runs of blank lines in the rendered body SHALL collapse to a single
blank row.

Sanitization SHALL be display-only: the body stored for the model, the body
stored in the session journal, and the text `/copy` reports SHALL remain the
unsanitized result.

SGR colour present in tool output SHALL survive while colour is on, and SHALL
be dropped together with every other escape when colour is off — ASCII mode,
`NO_COLOR=1`, or a theme that emits no colour.

#### Scenario: Progress-bar output cannot scribble over the row
- **WHEN** a `run` result contains carriage returns, erase-line sequences and repeated progress text
- **THEN** the rendered row and body contain the visible text only, with no escape sequence and no second-line overwrite

#### Scenario: Window-title escapes do not reach the screen
- **WHEN** captured output contains an OSC sequence that sets the window title
- **THEN** no part of that sequence is rendered in the transcript

#### Scenario: Blank-line runs collapse
- **WHEN** an expanded body holds several consecutive blank lines
- **THEN** the body renders a single blank row in their place

#### Scenario: Colour from the tool survives
- **WHEN** colour is on and the captured output carries SGR colour
- **THEN** the rendered body keeps that colour

#### Scenario: Colour-off mode strips escapes
- **WHEN** ASCII mode is active or `NO_COLOR=1` is set and the captured output carries SGR colour
- **THEN** the rendered body contains no escape sequence at all

#### Scenario: The model still sees the original output
- **WHEN** a call whose output carries control sequences completes
- **THEN** the body stored for the model equals the unsanitized output

### Requirement: Tool result expansion
Tool result bodies SHALL be collapsed by default. Expansion SHALL be
controlled per entry and for all entries at once:

- A left click on a tool row SHALL toggle that entry, wherever the mouse mode
  delivers transcript clicks (`ui.mouse = "on"`); in `auto`, `off` and
  `selection` modes no transcript click is delivered.
- `Ctrl+O` SHALL toggle the newest tool entry whose rows overlap the
  viewport, falling back to the newest tool entry in the transcript when the
  viewport holds no tool entry.
- `Ctrl+Shift+O` SHALL toggle all entries at once and SHALL clear per-entry
  state.
- On terminals that cannot report the Shift modifier, `Ctrl+O` SHALL keep the
  all-entries meaning, so expand-all is never unreachable.

An entry SHALL have an explicit per-entry state (`expanded`, `collapsed`) or
inherit the all-entries state, which SHALL default to collapsed. Toggling an
entry SHALL set its explicit state to the opposite of its current effective
state; expanding or collapsing all entries SHALL clear per-entry state. The
expanded body SHALL stay subject to the existing per-tool line caps and the
`… (N строк скрыто)` marker, and expansion state SHALL NOT be persisted
between sessions or transmitted to the agent.

#### Scenario: Click toggles one entry
- **WHEN** the mouse mode delivers transcript clicks and the user clicks a collapsed `grep` row
- **THEN** that entry expands and every other tool row keeps its current state

#### Scenario: Ctrl+O toggles the newest visible entry
- **WHEN** the viewport holds two tool rows and the user presses `Ctrl+O`
- **THEN** the newer of those two entries toggles and the older one does not

#### Scenario: Ctrl+O with no tool row in the viewport
- **WHEN** the user is scrolled to a region holding no tool row and presses `Ctrl+O`
- **THEN** the newest tool entry in the transcript toggles, even though it is off-screen

#### Scenario: Ctrl+Shift+O toggles everything
- **WHEN** one entry was expanded by click and the user presses `Ctrl+Shift+O`
- **THEN** all entries expand or all collapse together and the per-entry state is cleared

#### Scenario: Plain terminal keeps expand-all
- **WHEN** no keyboard protocol was negotiated and the user presses `Ctrl+O`
- **THEN** all entries toggle together, as before

#### Scenario: Height stays exact across per-entry toggles
- **WHEN** the user toggles one entry while scrolled up
- **THEN** the transcript height and the hidden-row count reflect the toggled body exactly

### Requirement: Tool body syntax highlighting
Expanded tool bodies SHALL be rendered with the same token colouring used for
fenced code blocks, under the same gates and theme roles. The language SHALL
be taken from the call's own target instead of a markdown fence: a `read`
body follows the read file's extension, each `grep` match follows its own
matched path, and `list`, `glob` and `run` bodies render unhighlighted,
because no language is known for them.

The `lineno<TAB>` prefix of a `read` body and the `path:line:` prefix of a
`grep` body SHALL be excluded from the token colouring and SHALL keep their
current presentation. Highlighting SHALL NOT change the body's text or
geometry: stripping SGR SHALL reproduce the unhighlighted rows exactly, and
each row SHALL have the same display width in both renderings. An unknown or
unsupported extension SHALL render plain. `ui.highlight = "off"`, ASCII mode,
`NO_COLOR=1` and a colour-free theme SHALL suppress token colouring.

#### Scenario: Lua read body is coloured
- **WHEN** a `read` of `src/tether/agent.lua` returns lines with a keyword, a string and a comment and the user expands it
- **THEN** those token kinds are rendered with distinct SGR styling

#### Scenario: The read prefix stays out of the colouring
- **WHEN** a highlighted `read` body is rendered
- **THEN** the line number and the tab that follows it carry no token colour, and the content begins at the same column as in the unhighlighted rendering

#### Scenario: Grep matches follow their own paths
- **WHEN** an expanded `grep` body matches a `.lua` and a `.json` file
- **THEN** each match row is coloured for that file's language

#### Scenario: Operations without a language stay plain
- **WHEN** the user expands a `run` body
- **THEN** no token colouring is applied

#### Scenario: Unknown extension stays plain
- **WHEN** a `read` body comes from a file whose extension is not a supported language
- **THEN** the body renders uncoloured

#### Scenario: Stripping colour reproduces the plain body
- **WHEN** SGR sequences are removed from a highlighted tool body
- **THEN** the result equals the same body rendered with highlighting off, row for row and column for column

#### Scenario: Highlight disabled
- **WHEN** `ui.highlight = "off"` or ASCII mode is active
- **THEN** tool bodies render with no token colouring

### Requirement: Diff rendering for write and patch
The body of a `write` or `patch` result SHALL render as a unified diff: added,
removed and context lines SHALL take the diff roles the theme defines, added
and removed lines SHALL carry old/new line numbers derived from the hunk
headers, and the body SHALL be syntax-highlighted where the target path names
a supported language. A body that does not parse as a unified diff SHALL
render as ordinary text, unchanged by this requirement.

The tool row's summary SHALL report the change as `+N −M` followed by a
proportional meter (`━━━━`; ASCII `#`), where the meter carries at least one
block for each non-zero side and its block counts follow the N:M ratio within
one block. A `write` summary SHALL distinguish a created file from an
overwritten one.

#### Scenario: Expanded write is a diff
- **WHEN** a `write` overwrites `src/app.lua` and the user expands the row
- **THEN** the body renders added lines, removed lines and context with the diff roles, old/new line numbers, and Lua token colouring

#### Scenario: Created file reads as a creation diff
- **WHEN** a `write` creates a file that did not exist
- **THEN** the summary says the file was created and reports `+N −0`

#### Scenario: Patch result renders as a diff
- **WHEN** a `patch` succeeds and the user expands the row
- **THEN** the applied diff is rendered with the diff roles and line numbers

#### Scenario: Meter reflects the ratio
- **WHEN** a change is `+12 −3`
- **THEN** the meter has both added and removed blocks, with the added side visibly longer

#### Scenario: Zero side has no blocks
- **WHEN** a `write` creates a file (`+34 −0`)
- **THEN** the meter shows added blocks only

#### Scenario: Non-diff body stays plain
- **WHEN** a `write` or `patch` result body is not a unified diff
- **THEN** the body renders as ordinary text

#### Scenario: Expansion caps still apply
- **WHEN** a diff body exceeds the configured expanded line cap
- **THEN** the body is capped and the `… (N строк скрыто)` marker reports the remainder

### Requirement: Word-level diff emphasis
Within a rendered diff, a removed line and the added line that replaced it
SHALL be compared word by word, and only the words that actually changed SHALL
keep the added/removed role: carried-over words SHALL be rendered muted so the
change itself stands out.

Pairing SHALL be conservative. Only a removed run and an added run of the same
length, adjacent in the diff, SHALL be paired. A pair whose lines share too
little content SHALL be left unemphasised, because muting incidental
characters would mislead. Pure insertions and pure deletions SHALL be coloured
whole. Lines longer than a documented threshold SHALL skip the comparison
entirely. Emphasis SHALL be expressed through the theme's roles; a theme
without colour SHALL render the diff without word emphasis rather than emit a
bare style.

#### Scenario: Only the changed word is emphasised
- **WHEN** a removed line and the added line that replaces it differ in one argument
- **THEN** that argument keeps the added/removed role in each line and the rest of both lines renders muted

#### Scenario: Unequal runs are not paired
- **WHEN** two removed lines are replaced by one added line
- **THEN** all three lines are coloured whole with no word emphasis

#### Scenario: Dissimilar pair is left alone
- **WHEN** replaced lines share only incidental punctuation
- **THEN** both lines are coloured whole with no word emphasis

#### Scenario: Pure insertion
- **WHEN** an added line has no removed counterpart
- **THEN** the whole line takes the added role

#### Scenario: Very long lines skip the comparison
- **WHEN** a replaced line exceeds the documented length threshold
- **THEN** both lines render with no word emphasis and the row stays on one wrapped segment per line

#### Scenario: Mono theme degrades
- **WHEN** the active theme emits no colour and a diff carries a replaced pair
- **THEN** the diff renders with no word emphasis and no stray escape sequence

### Requirement: Pending change preview
While a `write` or `patch` call is pending — its arguments are known and the
tool has not run — the TUI SHALL render the projected change on that entry
when the agent supplies one, in place of the result body, while the row keeps
its pending marker. The projection SHALL be collapsible and expandable like
any body, SHALL obey the same sanitization, highlighting, diff and line-cap
rules, and SHALL be replaced by the executed result when the call completes.
The preview SHALL be a read-only projection: it SHALL NOT be written to the
transcript history, SHALL NOT be sent to the agent, and SHALL be dropped when
the call is denied, cancelled or aborted.

When no projection is supplied — because the target is outside the workspace,
unreadable, or larger than the documented bound — the pending row SHALL render
as it does today: the pending marker and the tool name, with no diff.

#### Scenario: Pending write shows what will change
- **WHEN** a `write` call is pending with known arguments, the target exists and the user expands the row
- **THEN** the projected diff is rendered before the tool runs

#### Scenario: Pending patch shows the submitted diff
- **WHEN** a `patch` call is pending and awaiting confirmation
- **THEN** the projected diff is rendered on the entry while the menu is open

#### Scenario: No projection falls back to the plain row
- **WHEN** the pending call's target cannot be read or exceeds the document bound
- **THEN** the row shows the pending marker and name only, with no diff

#### Scenario: Result replaces the preview
- **WHEN** the pending call finishes
- **THEN** the entry carries the executed result, and the preview is gone

#### Scenario: Denied call drops the preview
- **WHEN** the user denies a pending call
- **THEN** no preview or result body remains on the entry

## MODIFIED Requirements

### Requirement: Mouse tracking
When `ui.mouse` is on the TUI SHALL enable SGR mouse reporting
(1006) and interpret clicks and wheel events on the transcript and
palette/confirmation items. A click on a tool row SHALL toggle that entry's
expanded state where the mode delivers transcript clicks (`ui.mouse = "on"`);
in the `auto`, `off` and `selection` modes no transcript click is delivered,
so those modes keep native text selection.

#### Scenario: Wheel scroll
- **WHEN** the mouse wheel is turned over the transcript
- **THEN** the transcript scrolls and follow mode is disabled on
  upward motion

#### Scenario: Click on a tool row
- **WHEN** `ui.mouse = "on"` and the user clicks a collapsed tool row
- **THEN** that entry toggles its expanded state

#### Scenario: No transcript clicks in auto mode
- **WHEN** `ui.mouse = "auto"` and no menu or palette is open and the user clicks a tool row
- **THEN** no transcript entry changes state

### Requirement: Viewport-proportional transcript rendering
A repaint SHALL render only what the viewport needs: the visible rows
plus the transcript entries that partially overlap the viewport. Both
the rendering work and the retained wrapped-line cache SHALL be
bounded by the viewport rather than by session length. The transcript
height SHALL be maintained incrementally, so the scroll indicator,
scroll clamping and follow-mode math do not rescan the transcript on
every repaint, and SHALL stay exact across appends, expand-all
(`Ctrl+Shift+O`) and per-entry expansion (`Ctrl+O`, click), thinking
toggle (`Ctrl+T`), `/clear`, `/new` and resize.
Cached wrapped lines SHALL be evicted for entries that remain
off-screen and re-derived on demand when scrolled back into view,
and cache memory SHALL stay within a documented bound on a long
session. Virtualized rendering SHALL be indistinguishable from a
full render: the same transcript SHALL produce the same visible rows
in the same order, at any scroll offset.

#### Scenario: Parity with a full render
- **WHEN** the same transcript is rendered with virtualization at any scroll offset
- **THEN** the visible rows equal those of a full render of the same transcript

#### Scenario: Long session repaint stays viewport-sized
- **WHEN** a session holds 50,000 transcript rows and the terminal is 24 rows tall
- **THEN** one repaint renders at most the visible rows plus the partially visible entries, and the wrapped-line cache stays within its documented bound

#### Scenario: Expand-all keeps the height exact
- **WHEN** the user expands all tool results while scrolled up
- **THEN** the transcript height and the hidden-row count reflect the expanded content exactly

#### Scenario: Per-entry toggle keeps the height exact
- **WHEN** the user toggles a single entry while scrolled up
- **THEN** the transcript height and the hidden-row count change by exactly that entry's collapsed/expanded row difference

#### Scenario: Resize re-wraps only what is needed
- **WHEN** the terminal is resized
- **THEN** visible rows are re-wrapped to the new width and the height is recomputed without a full-transcript re-render

#### Scenario: Scrolling back restores identical content
- **WHEN** the user scrolls far away from an entry and back to it
- **THEN** its rows are identical to the first render and the cache stayed bounded
