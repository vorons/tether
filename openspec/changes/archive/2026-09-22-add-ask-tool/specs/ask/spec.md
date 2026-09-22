# Spec Delta

## Purpose

Lets the agent put a structured question in front of the user — a list of
options, an always-available freeform answer, and inline notes — and receive the
answer back as a precise choice instead of prose.

## ADDED Requirements

### Requirement: Question set shape and bounds

The `ask` tool SHALL take one argument, `questions`: an array in which each entry
describes one question.

- `question` — the question text (required);
- `id` — a short stable identifier (optional; defaulted when absent);
- `description` — optional read-only context rendered above the options;
- `options` — a list of `{label, description?}` choices, each with a
  non-empty `label`;
- `multi` — when true the question accepts several selected options;
- `recommended` — the 1-based index of the option the model suggests.

A call SHALL carry at most 8 questions and each question at most 12 options;
beyond that the extra questions and options SHALL be dropped. Question text
SHALL be bounded to 1000 bytes and a description to 8000 bytes, each truncated
with the project's truncation marker, so one oversized field cannot fill the
transcript.

#### Scenario: Several questions in one call
- **WHEN** the model calls `ask` with two questions
- **THEN** both are asked, in the order given, as one answer set

#### Scenario: Bounds are enforced
- **WHEN** a call carries 9 questions, one with 13 options
- **THEN** the first 8 questions are asked and that question keeps its first 12 options

#### Scenario: Oversized text is truncated
- **WHEN** a question text is longer than 1000 bytes
- **THEN** it is presented truncated with an explicit marker

### Requirement: Malformed question sets degrade instead of hanging

A question set the model cannot express cleanly SHALL still reach the user in
the most useful answerable form rather than failing the call or parking the turn
forever. A question whose text is unusable SHALL be dropped; a missing `id`
SHALL be defaulted and duplicate `id`s SHALL be made unique; an option whose
`label` is missing, empty or not a string SHALL be dropped; a non-boolean `multi`
SHALL be treated as false; a `recommended` index outside the surviving options
SHALL be ignored. A question that keeps no usable option SHALL still be asked,
with only its freeform answer available.

A call that leaves no answerable question at all SHALL NOT raise a question
block: it SHALL produce an error tool result naming the problem, and the turn
SHALL continue.

#### Scenario: Empty option list still asks
- **WHEN** a question carries `options = {}`
- **THEN** the question is asked with only the freeform answer available

#### Scenario: Duplicate ids
- **WHEN** two questions share the id `scope`
- **THEN** the answers come back under distinct ids

#### Scenario: Nothing answerable
- **WHEN** every question in the call is unusable
- **THEN** no question is raised, the tool result is an error, and the turn continues

### Requirement: The answer reaches the model as a JSON payload

The tool result for an answered call SHALL be a single-line JSON object:

```
{"answers":[{"id":"…","question":"…","selected":["…"],"other":"…","notes":[{"option":"…","note":"…"}]}]}
```

`selected` SHALL always be an array and SHALL carry the chosen option labels
verbatim, so a single-answer question yields one element and a `multi` question
one element per toggle; it SHALL be empty when the question was answered only
through the freeform row. `other` SHALL carry the freeform text, and `notes` the
per-option notes keyed by the option label they were written on. `other` and
`notes` SHALL be omitted when empty, and the answers SHALL appear in the order
the questions were asked. The payload SHALL itself be the tool result body, so
the model reads the same text the transcript summarises.

#### Scenario: Single choice
- **WHEN** the user picks `React` on a single-answer question
- **THEN** the payload carries `"selected":["React"]` for that question

#### Scenario: Multiple choices
- **WHEN** the user toggles `No breaking changes` and `Zero dependencies` on a `multi` question
- **THEN** the payload carries both labels in `selected`

#### Scenario: Freeform answer
- **WHEN** the user answers a question only through the freeform row with `Nuxt`
- **THEN** the payload carries `"selected":[]` and `"other":"Nuxt"`

#### Scenario: Answer order
- **WHEN** a call asks `scope` then `priority`
- **THEN** the answers array lists `scope` first

### Requirement: Notes travel with the answer

A note written on an option SHALL be returned with that option's label whether
or not the option was selected — a note is stated intent, not a selection — and
SHALL NOT be returned as an answer in `selected`. A note written on an option of
a question that was answered freely SHALL still be returned.

#### Scenario: Note on an unselected option
- **WHEN** the user notes `too heavy` on `Vue` and selects `React`
- **THEN** the payload carries `"notes":[{"option":"Vue","note":"too heavy"}]`

### Requirement: The recommended option is advisory

An option named by `recommended` SHALL be flagged as the model's suggestion and
SHALL NOT be selected, submitted, or ordered ahead of the others on its own; the
initial highlight SHALL stay on the first option, and the user's answer SHALL be
reportable exactly as chosen.

#### Scenario: Recommended is only flagged
- **WHEN** a question marks option 2 as recommended and the user submits without changing the highlight
- **THEN** option 1 is the answer and option 2 was only flagged as suggested

### Requirement: Cancelling a question continues the turn

When the user cancels an open question set, the tool result SHALL report the
cancellation (a payload whose `answers` array is empty and which names the
cancellation) instead of an answer set, no `error` event SHALL be raised, and
the turn SHALL continue so the model can proceed or ask differently. Cancelling
SHALL apply to the whole call: other questions of the same call are not asked,
and any further `ask` call already queued in the same step is cancelled too.
Non-`ask` calls queued in the same step SHALL still run.

#### Scenario: Cancel one question
- **WHEN** the user cancels a single-question call
- **THEN** the tool result reports the cancellation, no error banner appears, and the model's turn continues

#### Scenario: Cancel a queued batch
- **WHEN** two `ask` calls were queued and the user cancels the first
- **THEN** the second is not asked and its tool result reports the same cancellation

### Requirement: The tool is listed for the model

The built-in tool description SHALL name the `ask` tool and its `questions`
argument alongside the file and shell tools, so a session that uses the default
prompt can call it without the user editing `system_prompt`.

#### Scenario: Default prompt exposes the tool
- **WHEN** a session starts with the built-in prompt (no `system_prompt` set)
- **THEN** the description lists `ask` with its question shape

### Requirement: Non-interactive runs get an explanation

In a run with no interactive user (`--print`), an `ask` call SHALL NOT wait for
an answer, SHALL NOT be presented anywhere, and SHALL produce an error tool
result that says the user cannot be asked in this mode, so the model decides on
its own. The call SHALL NOT fail the run: the turn continues and the run's exit
status is unchanged by it.

#### Scenario: Print mode
- **WHEN** `--print` runs a turn whose model calls `ask`
- **THEN** the tool result explains that no interactive user is available, the model continues, and the run still prints its answer
