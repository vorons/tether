# Spec Delta

## Purpose

The interactive terminal UI: screen layout regions, markdown-lite
transcript rendering, mouse tracking, slash-command palette, input
history, status line, themes, ASCII fallback, and overlays.

## ADDED Requirements

### Requirement: Screen regions
The TUI SHALL lay out: an optional header (disabled by default),
the scrollable transcript region, a status line, and a bottom
input field. With `ui.alt_screen = true` the TUI SHALL enter the
alternate screen buffer on start and leave it on exit; with `false`
the native scrollback is kept.

#### Scenario: alt_screen default
- **WHEN** the user starts the TUI without config
- **THEN** the alternate screen buffer is used

### Requirement: Markdown-lite rendering
Assistant text SHALL render inline code, bold, italic, lists, and
headings; fenced code blocks SHALL render inside a bordered frame
using box-drawing characters (or ASCII in ascii mode). Text SHALL
word-wrap to the terminal width when `ui.wrap` is on.

#### Scenario: Code block framed
- **WHEN** a reply contains a fenced ``` block
- **THEN** the block is drawn in a frame with its contents
  indented

#### Scenario: ASCII mode
- **WHEN** `ui.ascii = true` (or "auto" on a non-UTF8 locale)
- **THEN** box-drawing and spinner glyphs map to ASCII
  equivalents and no high bytes are written

### Requirement: Streaming append
Transcript entries SHALL append deltas live: text chunks extend the
current assistant entry without re-rendering the whole history; tool
call entries appear as they start, with a summary line and a
collapsed body that expands on interaction.

#### Scenario: Tool result collapse
- **WHEN** a `read` result exceeds `ui.collapse.read` (20) lines
- **THEN** the body is collapsed to the cap with an expand marker

### Requirement: Token usage in status line
The status line SHALL show context usage as `used/budget (pct)%`
with a color step: green below the summarize threshold, yellow at
the threshold, red at 90%+.

#### Scenario: Near-full context
- **WHEN** usage is 92% of max_tokens
- **THEN** the token counter is red

### Requirement: Mouse tracking
With `ui.mouse = "auto"` the TUI SHALL enable SGR mouse
(`CSI ?1006 h` + `CSI ?1000 h`) only while a menu (confirmation,
palette) is open; wheel events SHALL scroll the transcript; clicks
SHALL select menu items. `ui.mouse = "off"` disables tracking
entirely. "auto" SHALL allow native text selection outside menus.

#### Scenario: Wheel over transcript
- **WHEN** the user scrolls with the mouse wheel
- **THEN** the transcript scrolls and a scroll indicator shows the
  position

### Requirement: Confirmation menu
Out-of-workspace tool calls SHALL show a menu: `[y] once`,
`[a] session`, `[A] always`, `[d] details`, `[n] deny`, `Esc`
cancel; digits 1..6 SHALL map to the same actions in order.

#### Scenario: Digit shortcut
- **WHEN** the user presses `3` on the menu
- **THEN** the `always` decision is taken

### Requirement: Palette
A trigger (`/`) SHALL open a command palette of slash commands
(`/clear /compact /model /resume /new /quit` and help content),
filterable by typing, selectable with arrows/Enter.

#### Scenario: Palette open and select
- **WHEN** the user types `/mod`
- **THEN** the palette filters to `/model` and Enter applies it

### Requirement: Help overlay
Pressing `?` SHALL show a keybinding help overlay; Esc closes it.

#### Scenario: Help toggle
- **WHEN** `?` is pressed in the input field
- **THEN** the overlay is shown and Esc dismisses it without
  submitting

### Requirement: Input field and history
The input SHALL support multi-line up to `ui.input_max_lines` (8),
UTF-8-aware cursor movement, and Up/Down history navigation from
`~/.tether/history.jsonl`.

#### Scenario: Up recalls last prompt
- **WHEN** the input is empty and Up is pressed
- **THEN** the last submitted prompt is loaded for editing

### Requirement: Themes
The theme engine SHALL map roles to SGR color attributes for the
`default` theme; the `mono` theme SHALL emit no SGR sequences.

#### Scenario: mono theme
- **WHEN** `ui.theme = "mono"`
- **THEN** transcript lines contain no escape color sequences

### Requirement: Keyboard protocol negotiation
At start the TUI SHALL try the Kitty keyboard protocol
(`CSI > 1 u`), then modifyOtherKeys, and fall back to plain
key parsing per `ui.keyboard_protocol` (`auto`/`kitty`/
`modifyOtherKeys`/`none`).

#### Scenario: Terminal without Kitty
- **WHEN** the terminal ignores `CSI > 1 u`
- **THEN** key parsing falls back to the next protocol

> drift: design.md §6.8 mentions "палитра и resume picker"; the
> shipped resume picker lists the last 10 sessions per workspace (README),
> not 100.
