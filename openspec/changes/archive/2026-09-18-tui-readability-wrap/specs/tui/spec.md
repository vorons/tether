# Spec Delta

## MODIFIED Requirements

### Requirement: Markdown-lite rendering
Assistant text SHALL render inline code, bold, italic, lists, and
headings; fenced code blocks SHALL render inside a bordered frame
using box-drawing characters (or ASCII in ascii mode). Text SHALL
word-wrap to the terminal width when `ui.wrap` is on: prose wraps
on word boundaries (greedy), and fenced code blocks soft-wrap
inside the frame with a continuation indent instead of truncating.
No visible content SHALL be lost to truncation when `ui.wrap` is
on. A single token longer than the available width (no spaces to
break on) SHALL be cut hard. Wrap width SHALL be counted in
display columns (wide East-Asian characters count as 2, ANSI
sequences as 0). When `ui.wrap` is off, lines SHALL be truncated
with a cut marker as before.

#### Scenario: Code block framed
- **WHEN** the assistant emits a fenced ```lua block
- **THEN** it renders inside a box-drawing border; long lines inside soft-wrap within the frame instead of truncating

#### Scenario: Prose wraps on word boundaries
- **WHEN** the assistant emits a sentence longer than the transcript width
- **THEN** no line breaks inside a word; the break falls on a space, and every rendered line fits the width

#### Scenario: Code block soft-wraps inside the frame
- **WHEN** the assistant emits a fenced block with a line longer than the frame inner width
- **THEN** the line renders on several framed lines with a continuation indent, the full content stays visible, and no cut marker appears

#### Scenario: Wide characters count double
- **WHEN** text contains East-Asian wide characters
- **THEN** wrapping accounts 2 columns per such character and no line overflows the width

#### Scenario: Overlong token is cut hard
- **WHEN** a single token without spaces exceeds the available width
- **THEN** it is cut hard at the width boundary

#### Scenario: Wrap off still truncates
- **WHEN** `ui.wrap` is off and a line exceeds the width
- **THEN** the line renders truncated to one row with the cut marker
