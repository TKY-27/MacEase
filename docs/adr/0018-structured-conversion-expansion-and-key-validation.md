# 18. Structured conversion expansion and key validation

Date: 2026-10-22
Status: Accepted

## Context

YAML value-count limits allow a large anchored scalar to be repeated thousands
of times. Expanding that document to JSON can require gigabytes despite its
small input. Foundation also collapses duplicate XML plist dictionary keys
before the existing typed conversion can reject them.

## Decision

- Reuse the 8 MiB conversion input cap for expanded YAML scalar and key UTF-8
  bytes. Extend the existing libyaml event budget to charge each alias for its
  complete scalar and key byte total before Yams composition. Preserve the
  existing depth and value limits.
- Cap YAML-to-JSON output at 8 MiB including the final newline. Reuse the JSON
  writer with a checked append operation and bounded string-escaping chunks.
  Check cancellation for events, converted values, and output fragments.
- Validate XML plist dictionary keys with XMLParser before Foundation decoding.
  Maintain a separate key set for each open dictionary, including dictionaries
  nested in arrays. Reject duplicates with the existing duplicate-key error.
  Disable external entity resolution and refuse entity declarations. Preserve
  the binary plist decoding path.
- Add no dependencies or settings. These bounded guards avoid replacing Yams,
  libyaml, or Foundation and do not promise a strict framework allocation cap.

## Consequences

Oversized YAML expansions fail explicitly before composition or before output
can exceed its byte cap. Valid smaller aliases retain their values and JSON
formatting. XML plist duplicate keys fail before values disappear. Binary plist
behavior and original-file protection remain unchanged.
