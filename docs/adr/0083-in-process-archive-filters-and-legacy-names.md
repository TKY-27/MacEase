# ADR 0083: In-process archive filters and legacy entry names

Date: 2026-11-25
Status: Accepted

## Context

libarchive 3.8.10 is built without iconv, LZ4 or LZO. Its register-all-filters
call enables external-command fallbacks for LZ4, LZOP, LRZIP and GRZIP and
reports them only as a warning, and a chained filter can hide such a layer
inside gzip. The supported inputs need only gzip, bzip2, xz and zstd.

Archives made on Japanese Windows store entry names in CP932 without a UTF-8
flag. The native readers refused such names, while Extract with HatchZip wrote
them as CP437 mojibake, split names whose trail byte is 0x5C into folders, and
consumed the archive. Byte structure alone cannot identify the encoding:
common CP437 names such as `Müller.txt` are also valid CP932. Paused HatchZip
sessions hold partly consumed archives that only the helper can finish.

## Decision

Register filters in one place, gzip, bzip2, xz and zstd only, and require
`ARCHIVE_OK` from each registration before any source opens. Register only the
formats each operation supports, refuse unfiltered raw input and external
filter signatures, and refuse ZIP inside another compression layer, whose
names cannot be checked by the seekable reader.

Decode names through one decoder with an explicit mode. UTF-8 always wins.
CP932 is a candidate only when Japanese is among the user's preferred
languages, and only if every non-UTF-8 name in the archive passes a strict
CP932 check; otherwise ZIP uses CP437, as ZIP tools traditionally do, and TAR
refuses. Read the preference at operation and session boundaries, never in
the decoder.

For new Finder extractions, inspect names before the helper starts. Route the
CP932 case to the native staged extractor, which keeps the archive and
supports Undo; keep everything else on the helper as before. Record the start
route and language snapshot in a versioned proof beside new sessions, and let
every paused session resume on the route it started with, with or without a
proof.

## Consequences

No archive operation starts an external decompressor. Japanese Windows ZIP
and TAR names extract correctly for users with Japanese preferred, through a
path that preserves the original. Without Japanese preferred, CP932 ZIPs
behave as before (CP437, helper, consumed archive), and with it a Western
CP437 name that is also valid CP932 shows Japanese characters: the preference
selects a rule, it does not prove the archive's origin. Non-UTF-8 TAR names
outside that rule are refused before anything changes. Because the native
route now receives archives the helper used to take, it refuses any archive
whose entries would collide on the destination volume (same decoded name,
case on a case-insensitive volume, Unicode normalisation) instead of letting
a later entry overwrite an earlier one; the check runs as entries are
written in staging and also covers RAR and explicit native extraction, which
had the same silent overwrite before. Inspection adds about
0.1 seconds for 100,000 ZIP entries in a warm Debug build; a gzip TAR is read
linearly. Old paused sessions keep their old naming so their remaining
content stays reachable. Other legacy encodings (GBK, Big5, EUC-KR,
Windows-1252) are not handled.

Alternatives rejected: detecting the encoding from byte statistics, which
cannot tell CP437 from CP932; accepting CP932 whenever it is structurally
valid, which renamed Western files; repairing the helper's decoder, which is
a separate pinned runtime; refusing paused sessions without a proof, which
would strand partly consumed archives.
