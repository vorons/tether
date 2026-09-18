# Spec Delta

## MODIFIED Requirements

### Requirement: Scroll position indicator
When the user scrolled up, the TUI SHALL report how many transcript
rows are hidden below as `↓ новые +N` (ASCII `v новые +N`). The
status line SHALL show the count, and the newest visible transcript
row SHALL additionally carry the same marker, right-aligned, while
following is off. Returning to the bottom SHALL re-enter follow mode
and remove both indicators. The in-transcript marker SHALL be
omitted when the count is zero, when the row is too narrow to hold
it without truncating the row's own content, and while an overlay is
open. The reported count SHALL stay exact across
appends, expansion toggles, `/clear`, `/new`, and resize.

#### Scenario: Indicator while scrolled up
- **WHEN** the transcript is scrolled up with lines below
- **THEN** the status line shows `↓ новые +N` with the count

#### Scenario: In-transcript marker
- **WHEN** the user scrolled up and 7 transcript rows are hidden below
- **THEN** the newest visible transcript row ends with `↓ новые +7` and the status line shows the same count

#### Scenario: Marker hidden at the bottom
- **WHEN** the user is in follow mode at the bottom of the transcript
- **THEN** neither the transcript row nor the status line shows the marker

#### Scenario: ASCII mode renders the marker in ASCII
- **WHEN** ASCII mode is active and the transcript is scrolled up
- **THEN** the marker renders as `v новые +N` with no non-ASCII glyphs

#### Scenario: No room for the marker
- **WHEN** the newest visible row is too narrow to hold the marker
- **THEN** the marker is omitted and the row content is rendered intact

#### Scenario: Count survives expansion
- **WHEN** the user is scrolled up, expands all tool results, and stays scrolled up
- **THEN** the reported hidden-row count equals the difference between the new transcript height and the viewport bottom

### Requirement: Palette
Typing `/` as the first non-blank character of the first input line
SHALL open a command palette listing the available slash commands
(`/clear /compact /model /resume /new /quit /copy /skills`), each
row rendering the command and its short description. Filtering SHALL
be a case-insensitive subsequence match over the command name:
prefix matches SHALL rank above interior matches, ties SHALL keep
the declared command order, and an empty filter SHALL list every
command in declared order. Selection SHALL use arrows and Enter, Tab
SHALL complete the selected command into the input, and Esc SHALL
close the palette leaving the typed text. Enter SHALL apply the
highlighted command only when the palette holds a match; with no
match the palette SHALL render no rows and Enter SHALL neither run a
command nor submit the input. The palette SHALL close when the
filter contains a space or the first character is no longer `/`.

#### Scenario: Palette open and select
- **WHEN** the user types `/mod`
- **THEN** the palette filters to `/model` and Enter applies it

#### Scenario: Fuzzy match
- **WHEN** the user types `/mdl`
- **THEN** `/model` is listed and selected

#### Scenario: Prefix outranks interior match
- **WHEN** two commands match, one by prefix and one only by an interior subsequence
- **THEN** the prefix match is listed first and is the initial selection

#### Scenario: Empty filter lists everything
- **WHEN** the user types `/`
- **THEN** every declared command is listed in declared order with its description

#### Scenario: No match
- **WHEN** the user types `/zzz` and presses Enter
- **THEN** the palette shows no rows, no command runs, and no message is submitted

#### Scenario: Space closes the palette
- **WHEN** the user types `/model ` (with a trailing space)
- **THEN** the palette closes and the text stays in the input

## ADDED Requirements

### Requirement: Live turn feedback
The TUI SHALL show turn progress while the agent works, without
waiting for the turn to finish. On submit it SHALL paint the waiting
state immediately: the newest transcript row SHALL carry a
`✻ tether думает…` placeholder with a spinner frame, and the status
line SHALL show a spinner with the elapsed seconds of the turn. The
placeholder SHALL disappear with the first `text_delta` or
`reasoning_delta` and SHALL give way to a caret `▌` (ASCII `|`) at
the end of the newest line while deltas keep arriving; the caret
SHALL NOT be drawn while the user has scrolled up or while an
overlay is open. Text and tool progress SHALL become visible during
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
- **THEN** the transcript shows the `✻ tether думает…` placeholder with a spinner and the status line shows the spinner and elapsed seconds

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
- **THEN** no placeholder, caret or elapsed field remains

#### Scenario: Confirmation clears the busy state
- **WHEN** a tool call requires confirmation and the menu is raised
- **THEN** the placeholder, caret and elapsed field are cleared while the turn waits for the user

#### Scenario: Caret is not drawn while scrolled up
- **WHEN** the user has scrolled up while deltas are still arriving
- **THEN** no caret is drawn on the newest visible row

#### Scenario: ASCII mode
- **WHEN** ASCII mode is active during a turn
- **THEN** the spinner uses ASCII frames, the caret is `|`, and no non-ASCII glyph is emitted by the feedback

#### Scenario: No repaint is required while nothing happens
- **WHEN** a tool runs for a long time without producing stream events
- **THEN** the TUI is not required to repaint and the last painted frame stays on screen

### Requirement: Turn separators
The TUI SHALL insert one dim separator row before each new user turn
in the transcript, carrying the local wall-clock submission time as
`── HH:MM ──` (ASCII `-- HH:MM --`). Separator rows SHALL behave as
transcript rows for scrolling and the transcript height, and SHALL
NOT be sent to the agent or added to the agent history. They SHALL be
controlled by `ui.turn_separators` (default on); with it off no
separator rows are created. The TUI SHALL NOT synthesize separators
for the messages restored by `-r` startup or `/resume`, because no
submission time is available for them. `/clear` SHALL drop separators
together with the rest of the transcript and `/new` SHALL drop them
with the previous session.

#### Scenario: One separator per turn
- **WHEN** the user submits two messages in a session
- **THEN** the transcript holds two separator rows, each immediately before its user row, in chronological order

#### Scenario: Separators carry the submission time
- **WHEN** a message is submitted at 14:32 local time
- **THEN** its separator row reads `── 14:32 ──`

#### Scenario: Disabled by config
- **WHEN** `ui.turn_separators` is false and the user submits a message
- **THEN** no separator row is added and the transcript is unchanged apart from the new turn

#### Scenario: Resume does not invent separators
- **WHEN** the TUI starts with `-r` and restored history holds two user messages
- **THEN** the restored transcript contains no separator rows until the next message is submitted

#### Scenario: ASCII mode
- **WHEN** ASCII mode is active and a turn separator is rendered
- **THEN** it is rendered as `-- HH:MM --` with no non-ASCII glyphs

### Requirement: Path completion
With `ui.path_completion` on (default) and a non-empty input, pressing
Tab outside an open palette SHALL complete the workspace-relative
path token under the cursor against the workspace contents:

- Exactly one candidate SHALL complete the token in place without
  opening the palette.
- Several candidates SHALL open the palette listing them, with the
  first candidate applied to the token so the user sees the current
  choice, and each further Tab press SHALL move to the next candidate
  and apply it, wrapping at the end of the list.
- Directory candidates SHALL be completed with a trailing `/` so that
  completing again lists inside them.
- Esc SHALL close the completion palette and restore the token exactly
  as typed before the first completion.
- With no candidate the input SHALL be left unchanged and no palette
  SHALL open.
- Candidates SHALL be limited to the workspace: absolute paths, `~`
  and `..` tokens SHALL NOT be completed, and no candidate outside the
  workspace SHALL be listed.
- Hidden entries (a leading `.`) SHALL be offered only when the typed
  token itself starts with `.`.
- The candidate list SHALL be capped at 200 entries; when the cap
  truncates the list the palette SHALL indicate that more candidates
  exist.
- Completion SHALL NOT send anything to the agent and SHALL NOT alter
  the agent history.
- With `ui.path_completion` false, Tab outside the palette SHALL be a
  no-op, as before.

#### Scenario: Unique candidate completes in place
- **WHEN** the input holds `read src/tether/ag` and `src/tether/agent.lua` is the only match
- **THEN** the token becomes `src/tether/agent.lua` and no palette opens

#### Scenario: Directory gets a trailing slash
- **WHEN** the token matches exactly one directory `src`
- **THEN** the token becomes `src/`

#### Scenario: Several candidates cycle
- **WHEN** two files match and the user presses Tab twice
- **THEN** the palette lists both and the token holds the second candidate

#### Scenario: Esc restores the typed token
- **WHEN** the user presses Tab on a token, then Esc
- **THEN** the token is exactly what was typed before the Tab press

#### Scenario: Hidden entries need a dot
- **WHEN** the token is `s` and the workspace holds `src` and `.secrets`
- **THEN** only `src` is offered

#### Scenario: Outside the workspace is not completed
- **WHEN** the token is `../etc/pass` and the workspace has no matching entry
- **THEN** the input is unchanged and no candidate outside the workspace is listed

#### Scenario: Disabled
- **WHEN** `ui.path_completion` is false and the user presses Tab outside the palette
- **THEN** the input and the palette state are unchanged

### Requirement: Copy targets
The `/copy` slash command SHALL open a palette of copy targets for the
current session, listed newest-first: the last assistant answer, the
last tool output, the last fenced code block, and the whole
transcript, each row showing the target and its byte size. Targets
without an available source SHALL be omitted, and with an empty
transcript the palette SHALL show no targets. Enter SHALL copy the
highlighted target to the system clipboard through OSC 52 (the
mechanism used by the last-answer shortcut) and SHALL show a
transient confirmation toast `✓ скопировано <size>` (ASCII
`[ok] скопировано <size>`); Esc SHALL close the palette without
copying. `Ctrl+Shift+C` SHALL keep copying the last assistant answer
directly. Copied text SHALL be the target's plain text with no ANSI
escape sequences. The toast SHALL be present in the repaint produced
by the copy action and SHALL be cleared by the next keypress; clearing
it SHALL NOT depend on a background timer.

#### Scenario: Target list is newest-first
- **WHEN** `/copy` is opened after a patch tool call and an assistant answer
- **THEN** the last answer is listed first, followed by the last tool output, the last code block, and the whole transcript

#### Scenario: Missing targets are omitted
- **WHEN** the session has no code block and `/copy` is opened
- **THEN** no code-block row is listed

#### Scenario: Copy writes OSC 52 and confirms
- **WHEN** the user selects a target and presses Enter
- **THEN** an OSC 52 sequence carrying the target's base64 text is written and the frame contains the confirmation toast

#### Scenario: Copied text has no escapes
- **WHEN** the copied target was rendered with color
- **THEN** the copied bytes contain the plain text only

#### Scenario: Last-answer shortcut unchanged
- **WHEN** the user presses `Ctrl+Shift+C`
- **THEN** the last assistant answer is copied without opening a palette

### Requirement: Skills in the palette
`/skills` SHALL list the skills discovered by the context-injection
discovery rules, in discovery order (first-wins name collisions are
already resolved by discovery), showing each skill's name and
description. Selecting a skill SHALL append a
reference naming that skill and its `SKILL.md` path to the input
buffer; the skill body SHALL NOT be read into the input and SHALL NOT
appear in the transcript. With no skill discovered the palette SHALL
render an explicit empty state and Enter SHALL leave the input
unchanged. Discovery problems SHALL NOT break the palette or the
session: they SHALL degrade to the empty state.

#### Scenario: Discovered skills are listed
- **WHEN** two skills are discovered and the user opens `/skills`
- **THEN** both names are listed in discovery order with their descriptions

#### Scenario: Selecting a skill only references it
- **WHEN** the user selects skill `deploy` whose file is `~/.tether/skills/deploy/SKILL.md`
- **THEN** the input gains a reference naming `deploy` and that path, and the body of `SKILL.md` is not inserted

#### Scenario: No skills
- **WHEN** no skill is discovered and the user opens `/skills`
- **THEN** the palette shows the empty state and Enter changes nothing

### Requirement: Code block syntax highlighting
Fenced code blocks SHALL be rendered with per-language token coloring
when the fence info string names a supported language: `lua`, `c`
(and `h`), `sh` (and `bash`), `python`, `js` (and `ts`), `go`, `rust`
and `json`. The language name in the fence SHALL match
case-insensitively and SHALL stay visible in the frame. Coloring SHALL
distinguish at minimum comments, string literals, numbers and
language keywords, and SHALL take its colors from the active theme.

Highlighting SHALL NOT change the block's text or geometry: removing
ANSI sequences from the highlighted rows SHALL reproduce the
unhighlighted rendering exactly, and each row's display width SHALL
be identical in both renderings. An unsupported, absent or
non-alphabetic fence info string SHALL render highlighted-free (as
today).

`ui.highlight` SHALL control the feature: `"off"` disables token
coloring, `"on"` enables it whenever color is available, and `"auto"`
(default) enables it when the terminal is color-capable. ASCII mode,
`ui.ascii` forced on, and `NO_COLOR=1` SHALL suppress token coloring
regardless of `ui.highlight`, leaving pure-ASCII output.

Color depth SHALL be negotiated once at startup and SHALL degrade:
24-bit SGR when `COLORTERM` advertises `truecolor` or `24bit`,
otherwise 256-color SGR, otherwise the 16-color palette. Rendering
SHALL stay legible at every depth.

#### Scenario: Lua block is colored
- **WHEN** the assistant emits a ```lua block with a keyword, a string, a comment and a number
- **THEN** those four token kinds are rendered with distinct SGR styling inside the frame

#### Scenario: Stripping color reproduces the plain block
- **WHEN** ANSI sequences are removed from a highlighted block
- **THEN** the result equals the same block rendered with highlighting off

#### Scenario: Fence label is case-insensitive
- **WHEN** the fence reads ```LUA
- **THEN** the block is highlighted as Lua

#### Scenario: Unknown language stays plain
- **WHEN** the fence reads ```brainfuck or has no info string
- **THEN** no token coloring is applied

#### Scenario: Highlight disabled
- **WHEN** `ui.highlight = "off"`
- **THEN** code blocks render with no token coloring

#### Scenario: ASCII and NO_COLOR win
- **WHEN** `NO_COLOR=1` or ASCII mode is active and `ui.highlight = "on"`
- **THEN** the output carries no ANSI sequences and no non-ASCII glyphs

#### Scenario: Truecolor when advertised
- **WHEN** `COLORTERM=truecolor` and highlighting is active
- **THEN** token colors use 24-bit SGR sequences

#### Scenario: Degraded depth
- **WHEN** `COLORTERM` is unset and the terminal reports 256 colors
- **THEN** token colors use 256-color SGR sequences and the block stays readable

### Requirement: Viewport-proportional transcript rendering
A repaint SHALL render only what the viewport needs: the visible rows
plus the transcript entries that partially overlap the viewport. Both
the rendering work and the retained wrapped-line cache SHALL be
bounded by the viewport rather than by session length. The transcript
height SHALL be maintained incrementally, so the scroll indicator,
scroll clamping and follow-mode math do not rescan the transcript on
every repaint, and SHALL stay exact across appends, expand-all
(`Ctrl+O`), thinking toggle (`Ctrl+T`), `/clear`, `/new` and resize.
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

#### Scenario: Resize re-wraps only what is needed
- **WHEN** the terminal is resized
- **THEN** visible rows are re-wrapped to the new width and the height is recomputed without a full-transcript re-render

#### Scenario: Scrolling back restores identical content
- **WHEN** the user scrolls far away from an entry and back to it
- **THEN** its rows are identical to the first render and the cache stayed bounded

## REMOVED Requirements

### Requirement: Help overlay
**Reason**: The `?` help overlay has not existed in the code since M9, when the help, status and log overlays were removed from the TUI; the palette and the `KEYMAP` table no longer reference it either, so the requirement describes behavior the system does not provide and lists a keybinding set that predates input history, tab completion and copy. Keeping a removal here rather than editing the main spec directly lets `openspec archive` apply the change to `openspec/specs/tui/spec.md` in the normal way.
**Migration**: None required. Pressing `?` already behaves as ordinary input text, which is the current shipped behavior. Bindings stay documented in `README.md` (TUI features) and in the `KEYMAP` table in `src/tether/ui.lua`. If in-app discoverability comes back later, it should arrive as a new requirement describing the current binding set, not as this one.
