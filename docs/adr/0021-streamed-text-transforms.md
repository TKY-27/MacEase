# 21. Streamed text transforms

Date: 2026-10-22
Status: Accepted

## Context

Whole-input decoding and encoded output copies put 400 MB text conversions
above section 16's 1.5 GB resident target. Draining FileHandle read pools alone
cannot remove these representations. JSON also retains parser bytes and a
value tree. The original file must remain untouched until the verified commit.

## Decision

- Reuse Foundation decoding and the existing encoders in 64 KiB chunks.
  Preserve incomplete multibyte sequences, BOM precedence and legacy ambiguity.
  Normalize byte or UTF-16 units with the existing algorithm, carrying CRLF
  state across chunks. Decode staged text in chunks during verification.
- Keep Shift_JIS replacement at Character boundaries, including combining
  sequences and line-numbered errors. Retain the last grapheme between reads.
  Refuse a single grapheme exceeding 1 MiB in UTF-8. Retained input is bounded
  by that allowance plus one decoded chunk before the guard runs.
- Stream JSON output using the existing JSONValue serializer and parser.
  Keep key order, duplicate keys, number literals, escaping and final-newline
  behavior. Do not introduce a second parser or a total-file size cap.
- Compare the staged file with the original in chunks for unchanged skips.
  Read user files normally; never memory-map them. Use the existing staging,
  output verification and commit protections.

## Consequences

UTF-8 and UTF-16 transforms use memory independent of total file size.
Shift_JIS has a bounded refusal for pathological combining sequences, rather
than changing replacement behavior or retaining an unbounded Character.
The limit applies to one grapheme, not ordinary large text files.
JSON parsing and sorting remain proportional to document structure and do not
guarantee section 16's target. A fully streaming parser is deferred; measured
serializer improvements do not establish a full-app memory result.
There is no new library, dependency notice or translation catalog entry.
