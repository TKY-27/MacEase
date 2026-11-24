# ADR 0086: Default for content that cannot be kept

Date: 2026-11-25
Status: Accepted

## Context

ADR 0075 replaced refusals with a per-file question before leaving out
timecode, subtitles, chapters or other content an output cannot carry. Batches
of MKV or MOV files then asked once per file, and answering in Activity
resubmitted files as separate batches, splitting successes, warnings,
notifications and history. Users who always answer the same way for new files
had no way to say so, and a replacement must never lose content without an
explicit answer.

## Decision

Add Settings > General > If some content can’t be kept, with Ask (default) and
Save without it. Carry the choice on the operation request, or on the
Finishing Recipe batch request, and enforce it in the engine before encoding,
against the item's actual commit disposition and its inspected identity
stamps. An item saved as a new file continues once in the same batch, with the
ordinary warning, commit, Activity and notification paths. A real replacement
always asks. A refusal after encoding has started keeps the manual question.
Finishing Recipes pass the policy to their engine batch instead of approving
omissions in the app.

## Consequences

New-file batches with such content finish in one batch without questions when
the user chose so, and every omission is still reported on the result.
Replacing an original never omits content silently. Settings saved before the
choice existed decode as Ask, and Reset All restores Ask. A source that
changes before continuation stops as changed without being inspected again.
The editor's open sheets, Trim and Enhance keep their own questions.

Alternatives rejected: applying the choice to replacements, which would drop
content from the only copy; resubmitting continued files as new batches,
which split results; letting the app approve omissions for recipes, which
bypassed the engine's stamp checks.
