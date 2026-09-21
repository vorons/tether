# Spec Delta

## ADDED Requirements

### Requirement: Tool-call start carries arguments and a projected change
The `tool_call_start` event the agent emits to the UI SHALL carry the call's
parsed arguments, so a renderer can identify the target it is about to touch
without re-parsing the raw model output.

For a `write` or `patch` call the event SHALL additionally carry a read-only
projection of the change it will make, computed from the call arguments before
the tool runs: the target path, which kind of change it is (new file,
overwrite, or patch), the projected unified diff, and its added/removed line
counts. For every other tool no projection SHALL be emitted.

The projection SHALL be computed without side effects: the target is resolved
with symlinks and SHALL lie inside the workspace, a file larger than the
documented bound SHALL NOT be read, nothing SHALL be written, and no history
or journal entry SHALL be produced. A projection that cannot be computed
(unreadable or oversized target, target outside the workspace, malformed
patch, arguments that do not address a file) SHALL be omitted; the call itself
SHALL proceed unchanged, and the event SHALL still carry the parsed arguments.

#### Scenario: Pending write carries a projected diff
- **WHEN** the model emits a `write` call for an existing file inside the workspace
- **THEN** the `tool_call_start` event carries the parsed arguments plus a projection whose diff describes the content change

#### Scenario: New file projects a creation diff
- **WHEN** a `write` call targets a path that does not exist yet
- **THEN** the projection reports a new file and its diff is entirely additions

#### Scenario: Patch projects the submitted diff
- **WHEN** the model emits a `patch` call whose arguments carry a unified diff
- **THEN** the `tool_call_start` event carries a projection with that diff and its counts

#### Scenario: Oversized target is not read
- **WHEN** a `write` call targets a file larger than the documented bound
- **THEN** the event carries the parsed arguments and no projection, and the file is not read

#### Scenario: Outside-workspace target is not read
- **WHEN** a `write` call targets a path outside the workspace
- **THEN** the event carries the parsed arguments and no projection

#### Scenario: Projection never mutates anything
- **WHEN** a `tool_call_start` event for a `write` or `patch` call is produced
- **THEN** the target file and the agent history are unchanged

### Requirement: Write and patch results carry the applied diff
A successful `write` SHALL describe its change as a unified diff — a creation
diff when the file did not exist, otherwise a diff against the previous
content — and a successful `patch` SHALL carry the applied unified diff.

For these two tools the diff SHALL be the result body, so the text the UI
offers on expansion and the text appended to the model's history stay the same
text, subject to the existing truncation maximum. The one-line summary SHALL
report `+N −M`, and for `write` SHALL say whether the file was created or
overwritten. When the previous content could not be read, the result SHALL
fall back to the existing body (the written path for `write`, the applied-file
list for `patch`) and its summary SHALL NOT claim a diff it does not have.

#### Scenario: Overwrite reports a diff
- **WHEN** a `write` replaces the contents of an existing file
- **THEN** the result body is a unified diff of the old and new content, the summary reports `+N −M` and an overwrite, and the model's history carries that same diff

#### Scenario: Creation reports a diff
- **WHEN** a `write` creates a file that did not exist
- **THEN** the result body is a diff made of additions, the summary reports the file as created with `+N −0`, and the model's history carries that same diff

#### Scenario: Patch reports the applied diff
- **WHEN** a `patch` applies cleanly
- **THEN** the result body is the applied unified diff and the model's history carries that same diff

#### Scenario: Failed call keeps the error body
- **WHEN** a `write` or `patch` call fails
- **THEN** the result is the error text as today, with no diff body

#### Scenario: Unreadable previous content falls back
- **WHEN** a `write` overwrites a file whose previous content could not be read
- **THEN** the result body falls back to the written path and the summary does not report diff counts

#### Scenario: Large change is truncated for the model
- **WHEN** the diff body exceeds the documented truncation maximum
- **THEN** the model's history carries the truncated body with the existing truncation marker
