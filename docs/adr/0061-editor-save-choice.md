# ADR 0061: Per-save editor output mode

Date: 2026-11-17
Status: Accepted

## Context

The photo/video editor inherited the global output mode. Its view could override
that mode for execution after the model had already planned output naming with
the original settings. Naming and preservation could therefore disagree.

## Decision

Use a native split Save button. Its primary action and Return shortcut create
a new file. The dropdown offers Replace Original with a Trash/Undo hint.
Disable replacement for multiple video sources, sources requiring new output,
and HDR color edits; show a reason only when new output is forced.

Resolve the chosen mode in the model and return the batch and its settings
together. Reject forced replacement before planning. Use that same settings
value for planning and execution, without consulting the global output mode.
Preview SDR permission follows forced-output and HDR conversion requirements.

Record source details for every photo the editor has opened and evaluate only
changed photos for replacement eligibility. Switching selection cannot bypass
an opened photo's constraints. Photos that were never opened keep the engine's
per-photo rules, which always save HDR color edits as new SDR files.

## Consequences

Ordinary editor saves always preserve originals and use edited-file naming.
Explicit replacement retains the shared staging, validation, Trash and Undo
sequence. Source preservation rules still apply, and preview behavior does not
change when the global output setting changes.
Opening multiple photos still decodes only the selected photo, so large
selections open quickly.
