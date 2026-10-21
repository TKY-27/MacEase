# 22. Metadata, expansion, and SDR input guards

Date: 2026-10-22
Status: Accepted

## Context

TIFF pages can have different metadata. Filtering the primary page and passing
its metadata to every page overwrites retained fields. Checking only that
page also misses removable fields on later pages.

Binary property lists can share a large scalar across thousands of references.
The input and value-count limits permit JSON output far above 8 MiB. Checking
after serialization allows that expansion to exhaust memory.

Video SDR classification uses AVFoundation. The general video engine's custom
demuxers do not make MKV, WebM, AVI, or FLV available to this path.

## Decision

- Inspect TIFF pages for selected metadata before deciding to skip. Rewrite
  each page's stored pixels with that page's filtered metadata. Keep cumulative
  allocation checks before creating the destination and check cancellation.
- Charge expanded scalar and key bytes during plist traversal for each
  occurrence, including shared references. Charge Base64 size before encoding.
  Reuse the bounded JSON serializer and reserve the final newline within the
  existing 8 MiB output cap. Keep Foundation decoding and existing typed tags.
- Limit video SDR applicability to MOV, MP4, and M4V. Reuse the menu's
  applicability rule in the host before AVFoundation classification, returning
  the existing unsupported-file error for other containers.

## Consequences

Retained TIFF page metadata stays distinct. Oversized plist expansions fail
without generating gigabytes of JSON. These guards retain existing libraries
and add no settings or strings. Foundation decoding still has no strict peak
allocation guarantee. Additional SDR containers require a compatible decoding
path before their menu entries can appear.
