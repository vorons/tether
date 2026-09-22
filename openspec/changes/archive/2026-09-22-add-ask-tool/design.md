# Design

## Context

See proposal.md — Why. Current state that shapes the approach:

- `agent.lua` already owns a "stop and wait for the user" mechanism: a tool call
  that needs the user is not executed in `drive_pending`; the call is marked
  `confirm_emitted`, a `confirmation` event is emitted and `main_loop` returns
  with `M.pending` still set. The UI paints the menu, and
  `resolve_confirmation` resolves it through `agent.confirm` and then resumes the
  turn with `agent.continue`. `M.continue` re-enters `drive_pending` first, so a
  parked queue is the normal resume path.
- The UI's confirmation menu is a *synthetic tail transcript entry*
  (`S.confirm_entry`, created by `sync_tail`), which is how it takes part in
  wrapping, the height index and scrolling. Its keys are dispatched by
  `handle_key` before the input field (`if S.confirmation then
  handle_confirmation_key(k); return end`).
- `tools.lua` is the file/shell layer with a workspace policy; `ask` touches
  neither. The turn's own state (`M.pending`) is the only place a call can wait.
- The pure-module pattern is established (`diff.lua`, `retry.lua`,
  `providers/common.lua`): a module that is a global in the built binary and a
  `loadfile` fallback in plain-Lua runs, wired into `LUA_MODS`,
  `tools/embed.lua`, the `luac -p` list and registered as a global in
  `src/host/main.c` before `agent`.
- The built-in tool listing exists twice — `agent.builtin_prompt` and
  `context.BUILTIN_PROMPT` — because `context.compose` builds the real base.
- `provider_common.json_encode` knows the `_array = true` marker for forcing
  array encoding of a table that would otherwise encode as `{}`.
- Constraints: no `load`, no new external dependency, all agent logic in Lua, and
  unit tests that construct the UI module with scripted keys
  (`run_ui_with(bytes, stubs)` in `tests/lua_tests.lua`).

## Goals / Non-Goals

**Goals:**

- Ask with zero new resume machinery: the question reuses the parked-turn path
  the confirmation menu already uses, so there is exactly one way a turn stops
  for the user.
- Question-shape handling (bounds, defaults, degradation, payload, summary) as
  pure data in → data out, testable without a UI or a transport.
- One answer payload per `ask` tool call, so the conversation stays contract-legal
  (one `tool` message per `tool_call` id) and the model reads a machine-readable
  choice instead of prose.
- A block that a keyboard-only user can complete, with the confirmation menu's
  conventions (digits, `Esc`, synthetic tail entry, dim decision row).

**Non-Goals:**

- Mouse support for the question block (the confirmation menu's click handling is
  row-band matching; extending it to a text editor is a separate change).
- A separate batch-review screen: answered questions are revisited with `←`
  instead of a review step before submission.
- Multi-line freeform answers or notes (single-line editors, like the input line's
  key handling without wrapping).
- Changing the confirmation menu's semantics, or letting an `ask` decision bypass
  the out-of-workspace confirmation policy.
- Streaming UI progress while the user answers (nothing is running; the turn is
  parked).
- Unifying the two built-in prompt copies.

## Decisions

### 1. A pure module `src/tether/ask.lua` owns the question set and the payload

`ask.normalize(args)` returns the answerable question list (bounded, defaulted,
degraded), `ask.encode(questions, answers)` returns the single-line JSON payload,
`ask.summary(questions, answers)` returns the one-line transcript text, and
`ask.cancelled_payload()` returns the cancellation payload. The module also
exposes the bounds (8 questions, 12 options, 1000/8000-byte text caps) and the
freeform row's label as constants.

*Why:* every rule in the `ask` spec's "Question set shape and bounds" and
"Malformed question sets degrade instead of hanging" requirements is arithmetic
over strings, and the payload is a fixed serialisation. Both are exactly what
`retry.lua` does for the retry policy, and both are testable in
`tests/lua_tests.lua` without a UI. Keeping them in `agent.lua` would grow an
already 886-line module and make the rules unverifiable without a parked turn.

*Alternatives considered:* inline in `agent.lua` (untestable rules, bigger
module); in `tools.lua` (it is the file/shell tool layer with a workspace policy
— `ask` has neither a path nor a shell); a UI-side helper (the agent needs the
normalised set for the event and the payload, so the logic would be duplicated or
the UI would have to answer with raw labels).

### 2. The `ask` call rides the existing pending queue; the turn parks

`drive_pending` gains one branch before the confirmation check: a call named
`ask` in a non-interactive run produces an error tool result immediately, and
otherwise marks itself emitted and emits one `ask` event with the call id and
`ask.normalize(args)`, then returns `false` — parking the turn exactly as a
confirmation does. Queued calls behind it stay pending.

*Why:* the turn must stop, the UI must paint, and the process must keep reading
keys — which is precisely the state a parked confirmation queue already
produces. A second mechanism would have to re-implement the "turn returned, UI
owns the terminal" handoff.

*Alternatives considered:* (a) blocking inside the turn on `tether.read_char` —
during a turn the UI is not reading stdin and the host watches it only for the
Ctrl+C interrupt, so a synchronous read would make the agent decode keys and
paint, duplicating the TUI inside the agent; (b) a coroutine that yields for the
answer — a broad change to the TUI's turn model for a feature that needs none of
it; (c) reusing the `confirmation` event with a `kind` field — the answer is a
selection/text payload rather than a decision, and the UI would have to branch on
the kind anyway, but every existing confirmation consumer (mouse hit-testing,
digit handling, details overlay) would have to learn the new kind first.

### 3. `answer_ask` plus the existing `continue`, mirroring `confirm`

`M.answer_ask(id, answer, cfg, on_event)` records `ask.encode(...)` (or the
cancellation payload) as the call's tool result, marks the call done, drives the
queue, and returns whether another interaction is pending. The UI then calls
`agent.continue`, exactly as `resolve_confirmation` calls `agent.confirm` and
then `agent.continue`.

*Why:* one resume path. `M.continue` already drives a parked queue before looping,
so a second queued `ask` call (or a confirmation) is handled without new code, and
the UI's existing "busy/waiting/paint then continue" sequence is reused verbatim.

*Alternatives considered:* having `answer_ask` resume the turn itself (the UI
would still need to paint the waiting state first, so the resume belongs with the
caller) and resolving the ask as a plain `M.confirm(id, "allow")` (no answer
payload would reach the tool result).

### 4. The block is a synthetic tail entry, like the confirmation menu

`S.ask` holds the interaction state and `sync_tail` gains an `ask_entry` case, so
the block renders through `render_entry` and participates in the height index and
scrolling. `touch_entry`-style version bumps re-render it when the highlight,
toggles, notes or editor text change.

*Why:* the confirmation menu established that a modal transcript tail entry is how
a "the turn is waiting on you" UI takes part in layout; a second rendering path
(an overlay region) would need its own height/scroll bookkeeping, and the overlay
region is a full-screen diff/error viewer with no input line.

*Alternatives considered:* a full-screen overlay (wrong interaction model — the
block scrolls with the answer it belongs to); reusing `S.confirm_entry` with a
different payload (the two have different key maps and rendering, and the states
would alias).

### 5. Modal key ownership with three modes

`handle_key` checks `S.ask` next to `S.confirmation`. The block has modes
`list` (navigation and submission), `other` (freeform editor) and `note` (note
editor on a highlighted option). In `other`/`note` the block consumes characters
and backspace into its edit buffer and only `Enter`/`Esc`/cursor keys act; `Esc`
returns to `list` without cancelling. Only `list`-mode `Esc` cancels the set.

*Why:* one handler with an explicit mode is how the palette already branches
(`palette_mode`), and it makes "keys the block does not use never reach the input
line" structural rather than a list of ignored keys. Separating the editor's `Esc`
from the cancel path is what keeps a typed note from being destroyed by the
reflex that closes a menu.

*Alternatives considered:* reusing the main input line for editing (the input's
`Enter` submits a turn — the modes would collide); a one-value-per-key map (the
note editor needs every printable character).

### 5b. The freeform row is submit-able once it holds text

`Enter` on the freeform row opens the editor while the question has no committed
freeform text, and submits (single) or advances (`multi`) once it has. The
editor's own `Enter` only ever commits.

*Why:* without this a question answered purely through the freeform row — or a
question the model sent with no options at all — cannot be submitted: the editor
commits and returns to the list, and `Enter` on that row reopens the editor. The
rule keeps the editor's commit conservative (a typo can be fixed before the
answer is sent) while making the freeform path reachable. It amends the tui spec
during implementation, with the user's agreement.

*Alternatives considered:* committing a non-empty freeform answer submits it
immediately (fewer keystrokes, but no review step and inconsistent with the
`multi` row behaviour), or a separate submit binding (explicit, but a binding
the user has to discover).

### 6. Per-question state inside one block, one tool result for the call

`S.ask` keeps `questions`, `qidx`, `sel`, and per-question
`answers[i] = {selected = {...}, other = "", notes = {label = text}}`. `Enter` on
the last question submits; `←` steps back to the previous question with its state
intact. The whole call produces one JSON payload.

*Why:* the OpenAI contract allows one `tool` message per `tool_call` id, so
answers cannot be spread over several results without synthesising extra messages;
a single block also avoids re-emitting an event per question and makes the
cancel-all rule trivial. Keeping per-question state is what makes "edit an earlier
answer" possible without a review screen.

*Alternatives considered:* an `ask` event per question with the agent emitting the
next on each answer (more round-trips through the queue, and cancellation would
have to unwind several calls); a review screen before submission (larger key map
and an extra UI state for little gain).

### 7. Non-interactive runs are a config flag checked by the queue

`app.lua`'s print path sets `cfg.non_interactive = true`; `drive_pending` turns an
`ask` call into an error tool result when it is set. The turn continues and the
run's exit status is untouched.

*Why:* the print path already constructs `cfg`, and the queue is the only place
that decides whether a call parks. `cfg` also gives tests a direct seam.

*Alternatives considered:* detecting a nil `on_event` (the print path passes one,
and the TUI always passes one — the signal would be wrong); parking regardless
(the run would hang until killed); letting `--print` fail the run (the tool is a
convenience the model can fall back from, and the existing exit-code contract is
about the answer, not about tools).

### 8. Cancelling resolves every pending `ask` call in the step

`answer_ask(id, {cancelled = true})` marks every still-pending `ask` call done
with the cancellation payload and drives the queue, leaving non-`ask` calls to run
normally.

*Why:* Esc means "stop asking". A model that emitted two questions would
otherwise re-prompt the instant the first was cancelled, which is the opposite of
what Esc communicates.

*Alternatives considered:* cancelling only the current call (immediate re-prompt);
cancelling the whole turn (the spec says the turn continues, so the model can
proceed or ask differently).

### 9. Both built-in prompt copies list the tool

`agent.builtin_prompt` and `context.BUILTIN_PROMPT` both gain:

```
- ask(questions) — ask the user to choose; options, multi, recommended, description
```

*Why:* `context.compose` is what actually supplies the base prompt in the built
binary, while `agent.builtin_prompt` is the fallback when composition is
unavailable; leaving either without `ask` means the default prompt can describe a
tool that is not listed, or list tools the model is never told about. A test
compares the two listings so they cannot drift again.

*Alternatives considered:* making `context.lua` read `agent.builtin_prompt` (a
real cleanup, but it is a prompt-composition change unrelated to this feature and
would touch the session-shape tests).

### 10. Payload serialisation reuses `provider_common.json_encode`

The payload is built with the shared encoder, using its `_array = true` marker for
the `answers`, `selected` and `notes` lists so an empty selection encodes as `[]`
rather than `{}`.

*Why:* the project has one JSON encoder and one parser (ADR: no `load`), and
`ask` must not become the second; the marker already exists for exactly this
shape problem.

*Alternatives considered:* a hand-written payload builder (a second encoder to
keep correct, and string escaping is the part that goes wrong).

## Risks / Trade-offs

- **The agent can park indefinitely on a question** → the user controls it: Esc
  cancels, Ctrl+C's existing double-tap quit still works outside the block, and
  `--print` never parks. A block left open simply leaves the turn waiting, like a
  confirmation menu today.
- **`ask` competes with the confirmation policy for the same "waiting" UI slot** →
  the block and the menu are both synthetic tail entries and key handlers checked
  in `handle_key`; when both exist the ask block is checked first and a
  confirmation raised while a question is open is resolved only after it, because
  the turn cannot progress past the parked ask anyway.
- **Notes on unselected options can look like answers in the transcript** → the
  spec requires notes to be returned separately from `selected` and the summary
  row names them as notes; the model sees `notes` as its own field.
- **A cancelled batch gives the model no answer for calls it made** → the
  cancellation payload is explicit, and the spec requires the turn to continue
  without an error, so the model's next message can proceed with a documented
  assumption rather than an empty tool result.
- **Two built-in prompt copies can drift** → a test compares them; the
  duplication itself is left as-is (Non-Goal).
- **Long option lists on a short terminal** → the block is a transcript entry and
  wraps like every other entry; the palette's windowing is not reused, so a
  question with 12 long options can fill the viewport. Bounded by the 12-option
  and 8-question caps in the spec.
- **Freeform answers are unstructured text** → deliberately: the freeform row is
  the escape hatch when the options do not fit, and it is returned under its own
  `other` key so the model can tell it apart from a chosen label.
- **The `ask` tool is a new prompt surface a user cannot switch off** → it is
  listed alongside the other tools and the model decides when to use it; a
  `system_prompt` override already replaces the listing for users who want to
  forbid it. No new config key is added.

## Migration Plan

1. Add `src/tether/ask.lua` and wire it into the Makefile (`LUA_MODS`, the
   `tools/embed.lua` argument list as `ask_lua`, and the `luac -p` list), and
   register it as a global in `src/host/main.c` before `agent` — the same order
   the other core modules use.
2. Land `ask.lua` with its unit tests first: the module is additive and nothing
   depends on it yet.
3. Add the agent side: the tool listing, the `ask` branch in `drive_pending`,
   `M.answer_ask`, and the `cfg.non_interactive` flag in the print path. Verify
   with agent-level tests that park on an `ask` call and answer it.
4. Add the UI block last: state, `sync_tail` entry, rendering, key handling and
   the summary row. Verify with scripted-key UI tests.
5. Documentation: the README tool/skills-adjacent description of the agent's
   tools, the `--print` note, and `docs/tech-spec.md`'s decision list.
6. Rollback: revert the change. Nothing persistent changes shape — the tool
   result is an ordinary `tool` journal entry, no config key is added, and an
   older binary simply never emits an `ask` event, so existing sessions resume
   unchanged.

## Open Questions

None: the deferrable choices (mouse support, a review screen, multi-line editors)
are recorded as Non-Goals, and the rest are settled in the specs.
