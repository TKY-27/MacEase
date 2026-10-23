# 32. Bounded natural JSON comparison

Date: 2026-10-23
Status: Accepted

## Context

ADR 0029 streams JSON parsing and sorting, but natural comparison still
materializes two complete folded keys. Small resident measurements cannot
establish bounded memory when those strings can be compressed or paged out.
Foundation's public string comparison requires complete strings; replacing
it with scalar or plain ICU comparison changes existing ordering.

## Decision

Keep folded keys as file spans and compare them through a narrow C bridge.
Reuse pinned ICU 78.3 collation with disk-backed collation elements, numeric
runs and skipped combining marks. Perform canonical decomposition one scalar
at a time and stable canonical ordering through disk-backed combining-class
buckets. Preserve the CoreFoundation comparison shell, including wrapping
ASCII numeric comparison, contextual retreat, width/composition handling and
its observed supplementary-character retreat behavior. Raw scalar tie-breaking,
pinning, descending order and JSON numeric lexemes remain unchanged.

Long common combining prefixes expose an existing Foundation defect: equal
UTF-8 bytes and UTF-16 units can compare in opposite directions depending on
string representation or process. The public CoreFoundation source obtains
an inline-buffer pointer using the old short range, then expands the range
after contextual retreat. This permits reading beyond its 64-unit buffer.
The observed OS behavior is consistent with that defect; its machine-code
cause has not been directly traced. Preserve deterministic content-based
ordering, matching Foundation with complete UTF-16 storage, rather than those
unstable results. Existing numeric, context and Unicode differential checks
remain required.

Use the official Apple Unicode 16 data for macOS 26.0–26.3 and Unicode 17
data for later verified systems. Two fixed public Foundation comparisons
select the known data generation; inconsistent results fail explicitly.
Do not call private system ICU APIs or fall back to whole-key strings.
These probes distinguish the known generations, not every possible future
change to Foundation. New OS collation changes require compatibility checks.

The comparator's largest allocation is a fixed 64 KiB page. Canonical ordering
has at most 255 nonzero combining classes plus four source/output pages:
259 pages, or 16.19 MiB, plus fixed metadata, Unicode tables and allocator
overhead. Other phases use fewer fixed caches. Scalar decomposition and
collation expansion are bounded by the pinned Unicode data. Temporary disk
usage is linear in input length; repeated skipped-mark replacement can cause
quadratic disk traffic. This is a memory bound, not a linear-time guarantee.

Check file-offset arithmetic before access. Scratch files are exclusive,
private and immediately unlinked; borrowed input descriptors remain open.
Cancellation checks surround I/O and occur within 1,024 page-array accesses.
Translate cancellation, I/O, allocation and collation failures into Swift
errors so the existing staging and commit protections remain authoritative.

## Consequences

ICU and Apple's legacy data add a permissive native dependency. The adapted
CoreFoundation shell retains Apache 2.0 and Swift Runtime Library Exception
notices. Source revisions, checksums, build adaptations and license texts
are pinned; generated upstream files retain their original notices.

Differential comparisons against Foundation protect observable compatibility,
while source analysis establishes the input-independent allocation boundary.
Neither replaces actual Release-app memory and file-safety acceptance.
The available macOS 26.6.2 and 27.0.1 systems use Unicode 17. Unicode 16
verification uses official data and an independent ICU comparison oracle;
execution of Foundation on macOS 26.0–26.3 is not claimed.
