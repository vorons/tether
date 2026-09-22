# Spec Delta

## ADDED Requirements

### Requirement: Question block

When the agent emits an `ask` event the TUI SHALL render a question block at the
tail of the transcript, built like the confirmation menu so it scrolls, counts
toward the transcript height, and is removed when it is resolved.

The block SHALL show:

- a `?` row with the question text, carrying an `N/M` progress indicator when the
  call holds more than one question;
- the question's `description`, when present, as read-only markdown-lite context
  above the options;
- one row per option, each prefixed with its 1-based index, the highlighted row
  rendered like the confirmation menu's selected row;
- the model's `recommended` option marked as the suggestion;
- on a `multi` question a toggled/un-toggled marker on every option row;
- a note already written on an option as a dim line beneath that option;
- a final freeform row, always present, inviting the user to type their own
  answer.

While the block is open the TUI SHALL clear the waiting placeholder, the caret
and the elapsed field, exactly as it does when a confirmation menu is raised —
the turn is waiting on the user. No header or hint row SHALL be added beyond the
rows above.

#### Scenario: Single question
- **WHEN** a single-question `ask` event arrives
- **THEN** the block shows the question text, its options with indices, and the freeform row, with no progress indicator

#### Scenario: Several questions
- **WHEN** a three-question `ask` event arrives
- **THEN** the first question is shown with a `1/3` indicator

#### Scenario: Description context
- **WHEN** the question carries a description
- **THEN** it is rendered above the options as formatted read-only context

#### Scenario: Recommended option
- **WHEN** the question marks option 2 as recommended
- **THEN** that row is marked as the suggestion while the highlight stays on the first option

#### Scenario: Waiting state cleared
- **WHEN** the block appears during a turn
- **THEN** no placeholder, caret or elapsed field is painted while it is open

#### Scenario: ASCII mode
- **WHEN** ASCII mode is active
- **THEN** every glyph the block introduces (toggles, note marker, progress) is rendered with an ASCII equivalent

### Requirement: Answering a question by keyboard

While the block is open it SHALL own the keyboard: a key the block does not use
SHALL NOT reach the input line, the palette or the transcript scroll.

- `↑`/`↓` SHALL move the highlight across the option rows and the freeform row.
- On a single-answer question, `Enter` SHALL submit the highlighted option and a
  digit `1..9` SHALL submit the option with that index.
- On a `multi` question, `Space` and a digit `1..9` SHALL toggle the option with
  that index without submitting, and `Enter` SHALL accept the current selection
  and move on.
- `Enter` on the freeform row SHALL open the freeform editor when the question
  has no committed freeform text, and SHALL submit the question (single answer)
  or accept the current selection and move on (`multi`) once text is committed,
  so a freeform-only answer can be sent.
- `Tab` on an option row SHALL open that option's note editor.
- `←` SHALL return to the previous question of the same call when one has already
  been answered, restoring its selections, freeform answer and notes for editing.
- `Esc` SHALL cancel the question set (see "Submitting and cancelling a question
  set").

#### Scenario: Pick with the arrow and Enter
- **WHEN** the user presses `↓` on a single-answer question and presses `Enter`
- **THEN** the second option is the answer and the question is submitted

#### Scenario: Pick with a digit
- **WHEN** the user presses `3` on a single-answer question with at least three options
- **THEN** the third option is submitted

#### Scenario: Multi-select
- **WHEN** the user presses `Space` twice on a `multi` question
- **THEN** two options are marked selected and nothing is submitted yet

#### Scenario: A freeform-only answer can be submitted
- **WHEN** the user opens the freeform row, commits `Nuxt`, and presses `Enter` again
- **THEN** the question is answered with that text and the set moves on

#### Scenario: Freeform row without text
- **WHEN** the user presses `Enter` on the freeform row with no committed freeform text
- **THEN** the freeform editor opens instead of submitting

#### Scenario: Return to a previous question
- **WHEN** the user has answered the first of two questions and presses `←` on the second
- **THEN** the first question is shown again with its answer still selected

#### Scenario: Unused keys do not leak
- **WHEN** the user types an ordinary letter while the block is open
- **THEN** the input line is unchanged and nothing is submitted

### Requirement: Freeform answer and option notes

Choosing the freeform row SHALL open a single-line editor inside the block,
prefilled with the current freeform answer; `Tab` on an option SHALL open a
single-line note editor for that option, prefilled with that option's saved note.
While an editor is open, characters and backspace SHALL edit its text
(the question highlight SHALL NOT move), `Enter` SHALL commit the text — an empty
commit clearing the value — and return to the option list, and `Esc` SHALL
discard the edits made in that editor and return to the option list without
cancelling the question set.

#### Scenario: Freeform text becomes the answer
- **WHEN** the user opens the freeform row, types `Nuxt` and presses `Enter`
- **THEN** the question is answerable with that text and the option list is shown again

#### Scenario: Note is written on an option
- **WHEN** the user presses `Tab` on an option, types a note and presses `Enter`
- **THEN** the note is shown beneath that option and travels with the answer

#### Scenario: Note discarded
- **WHEN** the user opens a note editor, types text and presses `Esc`
- **THEN** no note is recorded and the question set is still open

#### Scenario: Editing keys do not move the highlight
- **WHEN** the user presses `↑` while a note editor is open
- **THEN** the question's highlight is unchanged

### Requirement: Submitting and cancelling a question set

On the last question, `Enter` SHALL submit the whole answer set. Submitting SHALL
remove the block, append one dim row summarising the answers (the question ids
with their selected labels, freeform text and notes), and resume the turn.

`Esc` in the option list SHALL cancel the whole set: the block is removed, one
dim row records the cancellation, the tool result reports it without an error
banner, and the turn continues.

#### Scenario: Submitted answer is recorded
- **WHEN** the user submits answers to two questions
- **THEN** the block is gone, one dim row summarises both answers, and the turn resumes

#### Scenario: Cancel
- **WHEN** the user presses `Esc` in the option list
- **THEN** the block is gone, a dim row records the cancellation, and the turn continues without an error banner
