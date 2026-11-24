# ADR 0085: Archive contents in Finder Preview

Date: 2026-11-25
Status: Accepted

## Context

Finder Preview sent archives to Quick Look (ADR 0072), which shows little
more than an icon for ZIP and TAR files. Browse Contents already lists a ZIP in
its own window, but only after the user chooses it. A preview runs on every
selection change without consent, so reading an archive there must be bounded
by work done, not by file size: a few kilobytes of compressed input can expand
to gigabytes, and libarchive's 7z reader expands its encoded header and solid
RAR5 allocates large dictionaries before any read callback could stop them.
Entry names are untrusted text and can contain controls or direction changes.

## Decision

List ZIP, TAR, TAR behind exactly one of gzip, bzip2 or xz, and single
compressed files in process, reading only headers. Read ZIP through the
seekable reader and its central-directory preflight. Read compressed input in
two stages, decoding one layer in small input chunks and handing decoded
blocks to a filterless reader, so every block checks a deadline, cancellation
and a decoded-byte budget. Refuse chained filters and filters that need an
external program. Stop at fixed limits on entries, name bytes, decoded bytes
and time, and say which one stopped the list. Display names through an inert
text rule and copy only the stored path. Keep 7z and RAR on Quick Look. Add an
Archives type to Settings > Finder Windows, on by default.

## Consequences

Selecting a ZIP or TAR in Finder shows its contents without extracting,
staging or writing anything, quarantined archives included. Large or hostile
archives show a partial list with the reason. Entry previews, opening and
dragging rows remain with Browse Contents. 7z and RAR contents need an
isolated helper process with time and memory limits before they can be listed
automatically. Behaviour in a real Finder window and with VoiceOver has not
been exercised.

Alternatives rejected: listing 7z and RAR in process, for the unbounded header
expansion above; reusing the Browse Contents session, which materializes
entries for preview and keeps a window-scoped lifetime; leaving archives on
Quick Look.
