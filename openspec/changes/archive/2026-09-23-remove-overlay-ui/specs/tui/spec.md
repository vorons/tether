# Spec Delta

## RENAMED Requirements

- FROM: `### Requirement: Error banner and overlay`
- TO: `### Requirement: Error banner`

## MODIFIED Requirements

### Requirement: Confirmation menu
Out-of-workspace tool calls SHALL show a menu: `[y] once`,
`[a] session`, `[A] always`, `[n] deny`, `Esc` cancel; digits 1..5
SHALL map to the same actions in order (`1..5` = allow, session,
always, deny, cancel). There SHALL be no `details` option, no `[d]`
binding, and no separate diff view: the projected diff is the pending
tool-row in the transcript, and the result body is available through
expansion. Every decision (including Esc) SHALL clear the menu.

#### Scenario: Digit shortcut
- **WHEN** the user presses `3` on the menu
- **THEN** the `always` decision is taken

#### Scenario: Digit 4 is deny, not details
- **WHEN** the user presses `4` on the menu
- **THEN** the `deny` decision is taken and no overlay or details pane opens

#### Scenario: d is unbound
- **WHEN** the user presses `d` on the menu
- **THEN** the menu stays open and no details view opens

#### Scenario: Esc cancels
- **WHEN** the user presses Esc on the menu
- **THEN** the turn is cancelled and the menu is gone

### Requirement: Error banner
On an agent or API error the TUI SHALL show a one-line error banner
above the input. Enter or Esc on the banner SHALL clear it and
return the input to normal use immediately; neither key SHALL open a
modal view. The full error text SHALL go to the debug log when
`--debug` / `cfg.debug` is enabled and SHALL NOT be written to a
transcript row. While the banner is visible it does not own the
keyboard beyond Enter/Esc clearing it: a subsequent Enter (after the
banner is dismissed) SHALL submit normally.

An `aborted` turn is not an error: it SHALL append the dim
`⏹ прервано (Ctrl+C)` transcript row (ASCII `[x] прервано (Ctrl+C)`)
instead of raising the banner, and SHALL clear the waiting, streaming and
pending-retry indicators so no stale spinner or backoff stays on screen.

#### Scenario: Dismiss and send
- **WHEN** an error occurred, the user clears the banner with Enter
  or Esc, types a new message, and presses Enter
- **THEN** the new message is sent to the agent

#### Scenario: Enter clears the banner
- **WHEN** an error banner is showing and the user presses Enter
- **THEN** the banner is cleared and no overlay opens

#### Scenario: Esc clears the banner
- **WHEN** an error banner is showing and the user presses Esc
- **THEN** the banner is cleared and no overlay opens

#### Scenario: Full error text reaches the debug log
- **WHEN** `cfg.debug` is on and an `error` event arrives with full text
- **THEN** the debug log contains that text and the transcript gains no row carrying it

#### Scenario: Full error text never reaches the transcript
- **WHEN** an `error` event arrives
- **THEN** no transcript row is appended for the error message body

#### Scenario: Banner persists until next submit
- **WHEN** an error banner is showing and the user submits a new
  message without first clearing the banner
- **THEN** the banner clears as part of the submit (or Enter on the banner itself)

#### Scenario: An abort shows no banner
- **WHEN** a turn ends with an `aborted` event
- **THEN** the transcript gains the interrupted row and no error banner is set

#### Scenario: An abort clears the indicators
- **WHEN** a turn is aborted while it waited between attempts
- **THEN** no placeholder, caret, elapsed field or pending-retry field remains

### Requirement: Input field and history
The input field SHALL render as a box: one dim rule spanning the
terminal width directly above the input's rows, those rows rendered
with `ui.editor_padding_x` columns of horizontal padding on both
sides, and one dim rule spanning the width directly below them. The
input rows SHALL be padded out to the content width so that both rules
and the text rows have the same display width. The box SHALL NOT draw
side borders and SHALL NOT print a prompt marker inside it: the rules
delimit the input. `ui.editor_padding_x` SHALL be a whole number of
columns, 0 to 3; a larger value SHALL be clamped to 3, a negative one
to 0, and the value SHALL further be clamped so that the content keeps
at least one column. The rules SHALL be dim in every theme, including
`mono` (they are static glyph rows, not colored roles). In ASCII mode
the rules SHALL use `-` instead of `─`.

While secret mode is open, the input box SHALL render the masked secret
label instead of `S.input` (see Login secret mode).

The caret SHALL be drawn as a reverse-video block: when the cursor
sits on a character, that character SHALL be painted in reverse video
and no other cell SHALL be; when the cursor sits at the end of a row, a
reverse-video space SHALL be painted after the text. The block SHALL be
painted in the TUI's own frame and SHALL be the only caret shown while
the input has focus; the hardware terminal cursor SHALL stay hidden
for the whole session. In ASCII mode the block SHALL still
be used, since it is a video attribute and not a glyph.

The input SHALL show at most `ui.input_max_lines` rows at a time,
never fewer than one, and the window SHALL shift to keep the cursor row
inside it. While the window hides rows above the cursor, the top rule
SHALL carry a centered `↑ N more` label (ASCII `^ N more`); while it
hides rows below, the bottom rule SHALL carry a centered `↓ N more`
label (ASCII `v N more`). A scroll label SHALL be omitted when the rule
is too narrow to hold it without losing the rule's own glyphs.

The input field SHALL support multi-line editing up to
`ui.input_max_lines` (default 8) with UTF-8-aware cursor movement.
History navigation SHALL work as follows:
- Up/Down with a non-empty input moves the cursor between input
  lines, or scrolls the transcript when at a cursor edge.
- Up/Down with an empty input SHALL scroll the transcript (Up
  scrolls up, Down scrolls down and re-enters follow mode at the
  bottom).
- An explicit history key (Ctrl+Up / Ctrl+Down) SHALL recall
  previously sent messages one entry per press, most-recent first,
  continuing past the most recent entry on repeated presses.
- The recall list SHALL contain only messages that were committed
  to the agent; text typed and discarded without submission SHALL
  not enter the list.

#### Scenario: Framed input
- **WHEN** the input holds one line of text
- **THEN** a dim rule spans the width directly above the text row and another directly below it, the text row is padded out to the same width, and no `›` marker is printed

#### Scenario: Block caret on a character
- **WHEN** the input holds `abc` and the cursor sits after `b`
- **THEN** `b` is painted in reverse video and no other cell is

#### Scenario: End-of-line caret
- **WHEN** the cursor is at the end of the row's text
- **THEN** a reverse-video space is painted directly after the last character

#### Scenario: Hardware cursor stays hidden
- **WHEN** any frame is painted while the input has focus
- **THEN** no cursor-show escape is emitted by the input field's rendering

#### Scenario: Padding applied
- **WHEN** `ui.editor_padding_x` is 2
- **THEN** every input row starts and ends with two padding columns and the text never reaches the row's last column

#### Scenario: Scroll labels in the rules
- **WHEN** the input holds more rows than the window and the cursor is on the last row
- **THEN** the top rule carries `↑ N more` with the number of hidden rows above and the bottom rule carries no label

#### Scenario: Scroll label omitted on a narrow rule
- **WHEN** the terminal is narrower than the label needs
- **THEN** the rule renders as an unbroken run of its glyph with no label

#### Scenario: Scroll with empty input
- **WHEN** the input is empty and Up is pressed
- **THEN** the transcript scrolls up one line; no history text is
  inserted

#### Scenario: Recall walks the list
- **WHEN** Ctrl+Up is pressed three times with five committed
  messages
- **THEN** the input holds the 3rd-most-recent message

#### Scenario: Up with empty input no longer recalls
- **WHEN** the input is empty and Up is pressed
- **THEN** the transcript scrolls up; no history text is inserted

#### Scenario: Up recalls last prompt (superseded)
- **WHEN** the user previously sent a message and the input is empty
- **THEN** Up scrolls the transcript instead of inserting the last
  history text; recall moved to the explicit history key

#### Scenario: Discarded text not recorded
- **WHEN** the user types a line and clears it without Enter
- **THEN** it never appears in subsequent recall

### Requirement: Live turn feedback
The TUI SHALL show turn progress while the agent works, without
waiting for the turn to finish. On submit it SHALL paint the waiting
state immediately: the newest transcript row SHALL carry a
`✻ tether думает…` placeholder with a spinner frame, and the input
box's top rule SHALL carry the same spinner with the elapsed seconds of
the turn. The
placeholder SHALL disappear with the first `text_delta` or
`reasoning_delta` and SHALL give way to a caret `▌` (ASCII `|`) at
the end of the newest line while deltas keep arriving; the caret
SHALL NOT be drawn while the user has scrolled up or while the
palette, confirmation menu, ask block, or login secret mode owns the
keyboard. Text and tool progress SHALL become visible during
the turn: the TUI SHALL repaint while the turn is running, throttled
by a bounded number of skipped deltas, and SHALL repaint immediately
on state transitions (tool call start, tool result, error, abort,
confirmation). No background timer SHALL be required: repaints
driven by events and keypresses are sufficient, and the spinner
advances only when the TUI repaints. The waiting placeholder, caret
and elapsed field SHALL be cleared when the turn ends — after a
reply, on error, on abort, and when a confirmation menu is raised
(the turn is then waiting on the user) — and SHALL apply equally to a
turn resumed after a confirmation decision. The elapsed counter
SHALL reset at the start of each turn. In ASCII mode the spinner
SHALL use ASCII frames (the caret is `|`) and no non-ASCII glyph
SHALL be introduced by this feedback.

#### Scenario: Placeholder before the first token
- **WHEN** the user submits a message and no token has arrived yet
- **THEN** the transcript shows the `✻ tether думает…` placeholder with a spinner and the input box's top rule shows the spinner and elapsed seconds

#### Scenario: First delta replaces the placeholder
- **WHEN** the first text or reasoning delta arrives
- **THEN** the placeholder row is gone and the caret is drawn at the end of the newest line

#### Scenario: Text appears before the turn returns
- **WHEN** the model streams an answer
- **THEN** frames painted while the turn is still running already contain the streamed text

#### Scenario: Transitions repaint immediately
- **WHEN** a tool call starts or a tool result arrives
- **THEN** a frame for that event is painted without waiting for the delta throttle

#### Scenario: Cleared when the turn ends
- **WHEN** a turn ends after a reply, an error, or an abort
- **THEN** no placeholder, caret or elapsed field remains, and the input box's top rule is a plain dim rule again

#### Scenario: Confirmation clears the busy state
- **WHEN** a tool call requires confirmation and the menu is raised
- **THEN** the placeholder, caret and elapsed field are cleared while the turn waits for the user

#### Scenario: Caret is not drawn while scrolled up
- **WHEN** the user has scrolled up while deltas are still arriving
- **THEN** no caret is drawn on the newest visible row

#### Scenario: Caret is not drawn while a modal surface owns the keyboard
- **WHEN** the palette, confirmation menu, ask block, or login secret mode is open while deltas arrive
- **THEN** no caret is drawn on the newest visible row

#### Scenario: ASCII mode
- **WHEN** ASCII mode is active during a turn
- **THEN** the spinner uses ASCII frames, the caret is `|`, and no non-ASCII glyph is emitted by the feedback

#### Scenario: No repaint is required while nothing happens
- **WHEN** a tool runs for a long time without producing stream events
- **THEN** the TUI is not required to repaint and the last painted frame stays on screen

## ADDED Requirements

### Requirement: Session lists are palette modes
`/resume` SHALL open the shared palette with
`palette_mode = "resume"` and items from the session listing (never a
full-screen overlay). Enter SHALL resume the selected session, replace
the visible transcript via transcript seed, and append a resumed-session
marker; Esc SHALL close the palette with no side effects; arrows and
mouse selection SHALL behave as for `/copy`. `/model` SHALL open the
shared palette with `palette_mode = "model"` and items from the model
listing; Enter SHALL set `S.model_name` (and `S.cfg.model`) and append a
`→ модель: …` system row; Esc SHALL close without changing the model.
Neither mode SHALL set `S.overlay`.

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
- **THEN** `S.model_name` is that model and a system row `→ модель: …` is appended

#### Scenario: Model Esc does not change the model
- **WHEN** the model palette is open and the user presses Esc
- **THEN** `S.model_name` is unchanged and the palette closes

### Requirement: Login secret mode
Bare `/login` SHALL open the provider picker as
`palette_mode = "login"` (shared palette, never an overlay). Selecting a
provider SHALL enter secret mode: `S.login_secret = { buf = "" }` (a
dedicated buffer, never `S.input`), `S.overlay` SHALL stay unset, and the
provider picker SHALL close. While secret mode is open it owns the
keyboard: text/paste append to `buf`, backspace edits `buf`, Enter runs
`submit_login_secret(buf)` (store per auth rules, then clear secret mode),
Esc runs `cancel_login()` (clear secret mode, store nothing).
`render_input` SHALL paint a masked line `login <provider>: *…` (length
only); the plaintext secret SHALL NOT appear in the painted frame, in
`S.input`, or in any transcript row. OAuth failure that re-opens secret
mode SHALL NOT set an overlay.

#### Scenario: Picker Enter enters secret mode
- **WHEN** the user opens bare `/login`, selects a provider, and presses Enter
- **THEN** `S.login_secret` is non-nil, the palette is closed, and `S.overlay` is unset

#### Scenario: Secret never enters main input
- **WHEN** the user pastes a key while secret mode is open
- **THEN** `S.login_secret.buf` holds the text and `S.input` is unchanged

#### Scenario: Frame masks the secret
- **WHEN** secret mode has buffered text and a frame is painted
- **THEN** the frame contains mask characters and does not contain the plaintext

#### Scenario: Esc cancels without store
- **WHEN** secret mode is open and the user presses Esc
- **THEN** `S.login_secret` is cleared, nothing is stored, and no overlay is open

#### Scenario: Enter stores and clears
- **WHEN** secret mode has a non-empty `buf` and the user presses Enter
- **THEN** the credential is stored per auth rules, secret mode is cleared, and no overlay is open
