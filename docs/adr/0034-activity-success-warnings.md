# 34. Activity warnings on successful files

Date: 2026-10-23
Status: Accepted

## Context

Activity counted warnings attached to successful files as problems. A batch
that successfully processed 1,000 files with the same HDR-to-SDR notice said
it finished with 1,000 problems and repeated the notice for each file. The
conversion was successful, but its change in dynamic range still needs to be
visible.

## Decision

Count only item failures and history persistence failures as problems. Count
skips separately. A batch with successful files and warnings reports Done and
stays in Activity. Group identical warning messages in the row and show the
affected file count. Keep each file's warning in the full result details,
available through Show All. Keep true failures and skips visible and preserve
their existing status, color, and automatic-close settings. Cancellation
continues to take precedence.

Explicit Convert > SDR does not need a notice for its intended tone mapping.
Automatic HDR-to-SDR conversion to another output remains visible because it
changes dynamic range without an explicit SDR request.

## Consequences

Activity rows remain compact for large successful batches. The full report
still identifies every affected file. Successful warnings do not raise the
problem count or trigger failure presentation.
