# Proposal

## Why

Today the only decision the agent can put in front of the user is the
out-of-workspace confirmation menu, and it can only do that *about a tool it is
already running*. When a decision belongs to the user — which framework, which
of two candidate files, which scope for a refactor — the model either guesses or
writes an open-ended question into its reply; the user then answers as a plain
message, and the intent behind that answer (which option, under what
constraint, why not the alternative) is lost in prose. `pi-archimedes/ask`
shows the missing primitive: a structured prompt rendered in the terminal —
options, inline notes per option, a freeform fallback — whose answer travels
back to the model as a precise, machine-readable choice instead of a sentence.

## What Changes

- **New `ask` tool**, callable by the model with one or more questions. A
  question carries an `id`, the question text, an optional markdown
  `description` (rendered as read-only context above the options), a list of
  `options` with optional per-option `description`, a `multi` flag for
  multiple selection, and an optional `recommended` option index.
- **The turn parks for an answer, like a confirmation.** `ask` never executes
  locally: the agent emits an `ask` event and returns; the UI collects the
  answers and resumes the turn through a new `agent.answer_ask`. The tool
  result the model receives is the JSON answer set (selected labels, per-option
  notes, freeform text), with one dim transcript row summarising it.
- **Full question block in the TUI.** Arrow keys and digits select an option,
  `Enter` submits, `Space` toggles selection on a `multi` question, a built-in
  `Other (type your own)` row is always available, `Tab` opens an inline note
  editor on the highlighted option, and an option the model marked
  `recommended` is flagged. Several questions in one call are answered in
  order in one block (`N/M` progress) and submitted as one answer set.
- **`Esc` cancels the open question** — the tool result says the user declined
  and the turn continues, so the model can proceed or ask differently.
  Confirmation-menu `Esc` semantics (deny and stop the turn) are unchanged.
- **Non-interactive mode returns an error result.** Under `--print` there is
  nobody to ask, so `ask` yields a tool result explaining that, and the model
  decides on its own; the run is not failed by it.
- **A model that sends a malformed question set still gets an answer.** The
  question argument is normalised through a pure module: unusable questions are
  dropped, a question with no usable option keeps only the freeform row, and
  ids are defaulted and deduplicated, so a bad call degrades instead of
  hanging the turn. A call with nothing answerable at all returns an error
  result immediately.
- **Documentation** for the new tool in the README and `docs/tech-spec.md`
  (tool listing, answer shape, key bindings, `--print` behaviour).

## Capabilities

### New Capabilities

- `ask`: the structured-question tool — the question/option/answer data shape,
  normalisation of a malformed question set, the answer payload returned to the
  model (selection, per-option notes, freeform text), cancel semantics, and the
  non-interactive fallback.

### Modified Capabilities

- `agent-core`: the tool dispatch and pending queue gain the interactive `ask`
  tool — it emits an `ask` event instead of executing, the turn parks on it
  exactly like a confirmation, `agent.answer_ask` records the answer as the
  call's tool result and resumes the loop, and the built-in system prompt lists
  the tool.
- `tui`: a question block and its key handling — option list with selection,
  multi-select toggling, the freeform row and note editor, `recommended`
  marking, `N/M` progress across questions, the answer row appended on submit,
  and the clear/cancel paths.

## Impact

- `src/tether/ask.lua` (new): pure normalisation and answer-encoding module,
  unit-testable without a UI or transport.
- `src/tether/agent.lua`: `ask` joins the tool listing and dispatch; the
  pending queue emits `ask` events; `M.answer_ask` resolves one and continues.
- `src/tether/ui.lua`: the question block (synthetic tail entry, like the
  confirmation menu), its key handler, the freeform/note input mode, and the
  answer rows.
- `src/host/main.c`: register the new module as a global before `agent`, the
  way the other core modules are registered.
- `Makefile`: `LUA_MODS`, the `tools/embed.lua` argument list and the
  `luac -p` list.
- `tests/lua_tests.lua`: normalisation/encoding cases for `ask.lua`, agent
  cases for the parked turn and `answer_ask`, and UI cases driving the question
  block with scripted keys (selection, multi-select, freeform, note, cancel,
  non-interactive error).
- `README.md`, `docs/tech-spec.md`: the tool in the prompt/tool listing and the
  question-block behaviour.
