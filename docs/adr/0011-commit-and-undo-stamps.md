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

## Undo serialization and durability amendment

Date: 2026-10-21

History owns the asynchronous commit gate used by both JobEngine commits and
undo. An undo waiting for the gate suspends without holding the history actor
or the naming lock. Once admitted, each item takes the FileCommitter naming
lock, then coordinates every affected path in one multi-intent write. All
checks, moves and rollback finish before releasing coordination. No file
coordination callback acquires the naming lock or waits on the gate.

Running batch IDs stay registered until all items and the final history flush
finish. Undo refuses these batches without changing history. JobCenter keeps
the engine batch ID alongside its task ID so the menu hides the correct Undo
action. Appending entries clears an existing record's undone flag.

Replace and removal records store the actual Trash file's device, inode,
size and modification date while the commit holds its naming lock. Undo
requires that identity stamp to match before moving any file. A missing,
unreadable or reused Trash path consumes the entry as undoTrashItemMissing.
Legacy records without Trash identity remain readable but are skipped.

Backup records save immediately. Other records retain the existing throttle.
Undo and clear mark history dirty before saving so failed writes remain
retryable. Normal quit stops new app requests, cancels work and drains accepted
undo requests. The engine termination barrier waits for the commit gate, seals
future file mutations and flushes history. AppKit returns terminateLater and
replies only after the barrier finishes. The main actor never waits on a file
I/O semaphore. A failed flush cancels quit and reopens commit admission.
applicationWillTerminate only cleans up observers, because the history flush
has already completed before termination is permitted. Forced termination
cannot run this barrier.

This retains the section 3.5 commit sequence and the JobEngine class. Converting
it to an actor would not prevent interleaving across awaits. The shared gate
and one coordinated undo transaction provide the required serialization with
less API churn.
