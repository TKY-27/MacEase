# 23. Native audio copy timing

Date: 2026-10-22
Status: Accepted

## Context

AVAssetReader exposes compressed audio in media time, with propagating sample
attachments and output timestamps describing its audible presentation. The
packet bridge discarded this information. AVAssetWriter then chose its default
2112-sample AAC priming for a source whose edit trims only 1024 samples.

Restoring trim keys alone does not retain the original edit. Native remux probes
preserve it when the complete propagating attachment dictionary is retained.
Range reads also include required preroll and a final audible packet whose raw
timestamp exceeds the requested endpoint.

## Decision

- Snapshot native audio attachments with CoreMedia's public copy/set APIs.
  Keep the snapshot immutable and opaque; do not name private attachment keys.
- Recalculate leading and trailing trim when splitting compressed buffers.
  Restore attachments first, then packet trim, then output presentation time.
- Preserve sample-rate precision and rebase output timestamps when trimming.
  Retain reader-provided preroll and compare audible timestamps at the endpoint.
- Refuse rate-changing audio edits with an unsupported-timing error. Supporting
  their scaled packet durations requires a separate implementation.

## Consequences

Remuxing, video re-encoding with copied audio, HDR-to-SDR conversion, and native
audio extraction share the same timing bridge. No decoder, encoder, private API,
dependency, or setting is added. Existing non-default AAC fixtures cover the
source edit, audible onset, decoded length, and audio-to-video offset.
Native remux probes pass; full pipeline acceptance still requires the focused
tests on a Mac where the sandbox permits the package and codec operations.
