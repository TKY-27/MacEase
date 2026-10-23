# 29. Streaming JSON formatting and external sorting

Date: 2026-10-23
Status: Accepted

## Context

JSON formatting retained decoded input, parser bytes and a value tree.
Sorting could retain a second tree. Small values in large arrays exceeded
the resident-memory target even when a similarly sized record fixture did not.

## Decision

- Share one strict JSON scanner between the existing value-tree parser and
  file formatting. Retain numeric lexemes, member order and duplicate keys.
- Normalize file input through the existing streaming encoding reader.
  Pretty Print and Minify write scanner events directly to staged output.
- Sort using file-backed value spans and container records. Sort bounded
  batches of references, then merge them on disk. Keep the existing comparison,
  pinning, scope, primitive-array and indentation semantics.
- Keep scanner and output traversal stacks explicit at the existing depth
  limit. Check cancellation during reads, writes and sorting.
- Keep temporary files private, remove them on completion or failure, and
  leave final output installation to the existing commit sequence.
- Preserve interior U+FEFF when decoding UTF-8 chunks. Only the actual
  file-start BOM is stripped.
- Fold scalar-aligned chunks with Foundation's case-insensitive POSIX rules
  and store them on disk. Compare folded spans for case-insensitive ordering
  and pin matching. Natural ordering compares the two folded strings with
  the existing Foundation options and retains the raw ordinal tie-break.

## Consequences

Formatting no longer retains the complete input or a value tree. Sorting
trades temporary disk space and I/O for bounded value and reference buffers.
It adds no dependency or total-file cap.

Natural comparison still materializes two folded keys for its established
Foundation semantics. Memory can therefore depend on the largest compared
keys. This change does not waive the full-app memory acceptance requirement;
measurements and remaining checks are in `spikes.md`.
