# 14. Bounded document and structured conversions

Date: 2026-10-21
Status: Accepted

## Context

The conversion matrix lacked native rich-document export, rendered HTML,
typed property lists, and conversion of existing subtitle files. These need
the same staged verification and recoverable commits as existing exports.
General Office layout reconstruction and custom YAML or Markdown parsers would
add substantial complexity and risk.

## Decision

- Add Documents for DOCX, ODT, RTF, and RTFD, and Property Lists for plist.
  Keep HTML and Markdown in Text so existing source-text actions remain.
- Reuse AppKit document import and pagination. Bound ordinary input, compressed
  expansion, package contents, text length, and page count before downstream work.
  Reject unsafe package entries. Report rich-document fidelity limits.
- Render HTML in an ephemeral WKWebView with scripts and external requests
  disabled. Serve bounded local static resources through a custom scheme that
  checks the resolved path. Refuse oversized layouts and apply a timeout.
  PDF is a continuous page; this is not print-pagination parity.
- Use PropertyListSerialization and the existing typed JSON model. Represent
  dates and binary payloads with explicit tagged objects and escape dictionaries
  that contain the reserved tag key. Refuse null, duplicate keys, non-finite
  numbers, unsupported precision, and serialization that changes values.
- Reuse SubtitleCue and existing writers for a strict plain-text SRT/WebVTT
  subset. Refuse unsupported metadata or styling instead of discarding it.
- Keep all these exports Derived under both output-mode settings. Existing
  verification, collision avoidance, metadata copying, history, and Undo apply.
- Do not add unverified package pins or partial dependency stubs. Markdown
  HTML/PDF and YAML/TOML conversion require separately verified SwiftPM sources,
  exact resolutions, licenses, and generated notices before becoming available.

## Consequences

Finder exposes the implemented conversions directly. Source files remain intact.
The platform owns document layout and plist decoding; the explicit caps do not
constitute a measured framework memory bound. Complex Office content may reflow,
HTML cannot depend on scripts or remote resources, and structured conversion
does not retain comments or source formatting. Section 8.7 specifies the mapping
and limits. EPUB and general PDF-to-editable-document conversion remain excluded.
