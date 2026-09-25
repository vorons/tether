# Proposal: Transcript visual refresh

## What

Improve the visual style of the chat transcript (the `transcript` global) and
the input dock without changing agent behaviour or the canonical event
contract:

- Vertical breathing room between top-level transcript entities (turn separator,
  user, assistant, system) while keeping tool/thinking rows glued to their
  context. No gap between a separator and the user row it labels.
- Fenced code blocks drawn as a dim box frame with a corrected top-border width
  (off-by-one) and a visible language label; fence lines with trailing
  attributes (` ```python title=… `) and unknown languages are still recognised.
- Markdown-lite: inline `code`/`bold`/`italic` gain role colours, headings wrap
  and use a heading role, tables render aligned, ordered lists parse, list
  indentation shrinks, and runs of blank lines collapse to one.
- A one-row gap above the input box, between the transcript and the box's top
  rule.
- Tool name rendered in the accent role instead of warn (yellow).
- Slash palette: descriptions align for both commands and skills (dynamic
  label column width), and the skill hint reads `[skill]` instead of `[задача]`.

## Why

The current transcript reads as one dense block: adjacent turns, tool rows and
system notes have no separation, code blocks are awkward to scan, inline markup
is colourless, tables and ordered lists are not parsed, and the input box sits
flush against the transcript. The palette misaligns skill descriptions because
the fixed 10-column label field overflows once the `[задача]` hint is appended.
These are presentation-only gaps that make a long session hard to skim.

## Scope

One `openspec-change` (thin, incremental cut). No agent/turn/confirm API
changes; the external contract (`turn`/`confirm`/`answer_ask`/`continue` plus
canonical events) is untouched. Adds a single UI config knob `ui.block_gap`
(0 = today's compact layout, default 1).

## Decisions (confirmed with user)

- Code blocks: keep the box-frame look; fix the off-by-one, dim the frame, keep
  the language label readable.
- Gaps: a blank row *before* separator/user/assistant/system entities; tool and
  thinking rows stay attached; separator→user has no gap; system rows span full
  width (no rail indent) and only gain vertical gaps; first entity and the
  confirm/ask tails keep their own leading blank.
- New theme roles `code` and `heading`; `mono` theme stays colourless.
- Tool name colour: warn (yellow) → accent (cyan). Status markers (`…`, `⚠`)
  keep their warn colour.

## Out of scope

Session/journal format, agent loop, provider wiring, non-TUI surfaces.
