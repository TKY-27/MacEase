# ADR 0064: Success-first results

Date: 2026-11-17
Status: Accepted

## Context

Successful operations can report format or metadata limitations. Presenting
those warnings as primary results obscures whether processing succeeded.
Routine original-retention text adds noise, while generic read and conversion
failures leave users without a next step or accessible diagnostic details.
This supersedes the presentation rules in ADR 0034; historical ADRs and
validation records remain unchanged.

## Decision

Show successful Activity results with a success symbol and normal text color.
Group ItemWarnings as concise secondary notes inside a collapsed note-count
disclosure with info.circle. Count distinct notes per file and retain grouped
file counts and individual file notes. Failures use xmark.octagon.fill and red;
skips and cancellation remain neutral. Keep existing auto-close rules, so
successes with notes remain visible when Activity is open.

Successful batch notifications contain only the completion summary and any
note count. Never include the first note or raw engine diagnostics. Remove
routine original-retention boilerplate while retaining explanations of actual
replacement exceptions, including unavailable Trash and failed Trash moves.

Use localized failure headlines with an action, filename, cause and next step.
Expose the associated strings of decodeFailed, encodeFailed, commitFailed,
unexpected, unsupportedCodec and invalidInput.malformed as selectable Activity
Details, collapsed by
default. More Results reveals problems beyond the first five, including their
Details, even without a comparison or retry session. Omit the disclosure for an
empty diagnostic. Keep English source keys
and Japanese translations aligned through textual string-catalog edits.

## Consequences

Users can distinguish success from failure before reading optional information.
Diagnostic text remains available for reporting without crowding notifications.
Processing, output commits, original protection and Undo are unchanged. App-hosted
regressions cover success classification, note grouping, notification summaries,
neutral skips and failure diagnostics. Build, test execution and native rendering
and interaction verification remain required on a Mac outside this sandbox.
