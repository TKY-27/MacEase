# 11. Commit and undo stamps

Date: 2026-10-21
Status: Accepted

## Context

A replacement must not overwrite an input edited while conversion runs. Undo
must preserve edited folder descendants and renamed paths occupied by a new
file. Persisting every descendant makes history grow with folder contents,
and unreadable children must not turn a successful commit into a failure
without history.

## Decision

- Stamp non-directory inputs before the operation reads them. Compare size
  and modification date inside the coordinated replacement write, before
  cloning, Trashing or replacing. Skip a mismatch as `changedSinceScan`.
- Do not scan folder inputs for replacement stamps; folders never replace.
- Stream folder output metadata into a bounded summary: descendant count,
  total size, latest modification date and an order-independent SHA-256
  fingerprint of relative paths and metadata. Combine per-entry digests by
  XOR, avoiding a sorted descendant array. Include type, mode, size and
  modification time so edits before the latest date remain detectable.
- Do not follow symbolic links. Include unreadable paths and error codes in
  the summary. An incomplete summary cannot authorize undo.
- Keep the history record if an output stamp fails. Undo skips missing,
  incomplete or changed stamps. Old folder records without a summary and
  old rename records without a stamp remain readable but cannot undo.
- Include device and inode in rename stamps. Matching size and modification
  date alone must not authorize renaming a newly created destination.
- Case-only replacement undo must not treat its own output as an occupied
  original name on a case-insensitive volume. A failed case-change move
  after replacement returns the actual output path and a warning so the
  already committed replacement retains history.

## Consequences

History storage per folder is bounded independently of its descendant count.
Folder stamping still takes time proportional to the visible descendants.
Unreadable folders remain committed and recorded, but undo skips them because
unseen changes cannot be ruled out. File content edits preserving size and
modification date remain outside the stamp contract. SPEC.md sections 3.5 and
3.6 describe these rules.
