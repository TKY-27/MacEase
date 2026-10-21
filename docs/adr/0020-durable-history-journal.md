# 20. Durable history journal

Date: 2026-10-22
Status: Accepted

## Context

ADR 0011 requires immediate persistence of committed Trash-backed records.
Rewriting the complete snapshot for each record makes a batch quadratic in
written bytes. The recorded baseline was approximately 118 MB for 1,000
removals and 1 GB for 3,000. Throttling those writes would lose undo recovery
after an application crash, so it is not an acceptable optimization.

## Decision

- Keep the version-1 `history.json` snapshot and add an optional applied
  sequence number. A missing sequence means zero. Existing snapshots and
  legacy stamps retain their current interpretation.
- Append a compact JSON line to `history.journal` for each commit delta. Each
  line holds an increasing sequence and a batch's ID, operation, original
  timestamp and new commit entries. Retain only the last 100 batches when
  applying deltas. Appends reset the batch's undone flag.
- Synchronize Trash-backed appends and the directory before releasing the
  existing commit gate. Keep unsaved deltas until synchronization succeeds.
  A retry truncates any uncertain suffix to the last synchronized offset
  before rewriting pending entries. Other records retain the one-second
  throttle and the batch-completion flush.
- Compact at batch completion, launch recovery and orderly termination. Write
  an owner-only staged snapshot, synchronize it, rename it atomically over the
  snapshot, and synchronize the directory. Only then truncate and synchronize
  the journal. Snapshot and journal permissions are 0600.
- Replay complete lines beyond the snapshot sequence exactly once. Require
  increasing sequences and contiguous unapplied entries. Ignore only a final
  unterminated line. Preserve recovery files and block new commits, undo and
  clear if complete journal contents or a checkpoint cannot be read safely.
  Retain the existing set-aside behavior for unreadable legacy snapshots that
  have no journal.
- Keep compaction synchronous inside HistoryStore. Its state and checkpoint
  cannot interleave with appends. Undo retains the commit gate across its
  asynchronous file mutations. A compaction during an undo suspension records
  the pre-undo state; undo subsequently publishes its consumed entries.
- Undo and clear use snapshots. If publication or journal reset fails, a later
  commit must retry the complete snapshot before using append-only persistence.
  A failed flush still cancels orderly termination and can be retried.

## Consequences

A successful Trash record survives application termination without waiting
for the batch to finish. A crash before snapshot publication leaves the old
snapshot and journal. A crash after publication leaves duplicate journal
entries that the checkpoint ignores. A crash after reset leaves the complete
snapshot. Repeating recovery or compaction has the same result.

The journal uses Foundation and Darwin APIs; no new dependency or database
layer is required. Serialized appends plus one snapshot write make a single
batch's write volume linear. Snapshot compaction still encodes the retained
history. The in-memory history representation and stamp checks are unchanged.

Synchronization uses fsync semantics, covering application crashes and forced
termination. Sudden power loss and storage-device cache guarantees would need
a separate F_FULLFSYNC policy and are outside this change. See Apple's
[fsync documentation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html).

Regression tests exercise process kills before publication, between publication
and reset, and after reset; every truncation of the final frame; repeated
recovery; migration; retention; write failures; concurrent undo and compaction;
and an isolated 3,000-record write-volume upper bound.
