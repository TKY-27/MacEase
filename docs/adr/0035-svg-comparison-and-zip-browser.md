# 35. SVG comparison and ZIP browser

Date: 2026-10-26
Status: Accepted

## Context

The owner requested logo-oriented PNG vectorization, temporary ZIP browsing,
search and selective saving, followed by independent review and a signed release.
The existing SVG tracer, archive library and Derived commit machinery already
provide the core format and file-safety capabilities.

## Decision

Add `image.traceSVG` for one static PNG and `archive.browse` for one ZIP.
Use ordinary native windows with per-window task and staging ownership.
Keep existing conversion and extraction behavior. Share the tracer and use
libarchive's seekable ZIP reader without another dependency.

SVG comparison exposes color count and three detail levels and saves the
completed preview bytes. ZIP listing and selected reads have the resource,
path, integrity and cleanup limits recorded in SPEC section 8.14. Exported
outputs retain existing no-overwrite, quarantine and Undo guarantees. A
source snapshot is checked inside the coordinated final commit even when
the user selects a different output directory.

Before v1.1.0 publication, obtain at least three fresh GPT-6.1 Sol reviews
with high reasoning effort. Resolve all valid Critical and High findings and
material Medium findings, with two consecutive reviews free of unresolved
Critical or High findings. Freeze features for stability verification.

The owner explicitly continued M5/macOS 27 physical acceptance supplemented
by the macOS 26 VM. GitHub Actions remains disabled at the owner’s request. Run
local build, lint, device tests, release packaging and the manual acceptance
checklist. Publish a DMG signed with the existing identity and its checksum
from the tagged sources, then verify anonymous downloads and update discovery.

## Consequences

SVG tracing remains limited to flat-color paths; it does not reconstruct
editable text, gradients or photographic detail. ZIP previews temporarily
decompress selected content and remove app-owned files on close; this is
not secure erasure or control over operating-system caches. Crashes require
startup recovery. Failed mandatory checks continue to block publication.

## Review refinements

- Inspect actual ZIP central-directory records before libarchive builds its
  index. Enforce 100,000 records and 32 MiB of variable metadata, including
  extra fields and comments. Disable automatic AppleDouble processing.
- Limit paths to 256 components and hierarchy path storage to 32 MiB. These
  explicit errors prevent a small, deeply nested ZIP from exhausting memory.
- Export all selected members with one archive reader. Repeated directory
  records retain distinct browsing IDs but share one exported directory.
- Decode a guarded PNG byte snapshot and render the resulting SVG once in the
  comparison view. Save requires successful rendering of that revision.
- Read file stamps with lstat. Reference-date arithmetic preserves existing
  Foundation timestamps in durable Undo records without opening special files.
