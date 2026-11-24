# ADR 0082: Staged FFmpeg decode fallback

Date: 2026-11-25
Status: Accepted

## Context

The native engine reads media through AVFoundation, AudioToolbox and in-house
demuxers. Files people still keep, such as WMV, WMA, MPEG program streams,
RealMedia, DTS or WavPack, and Matroska or MOV files with an unsupported audio
codec, failed with a message naming the codec. Some failed only after the
video had opened, and an undecodable MOV audio track could abort the process.
The app already bundles LGPL `ffmpeg` and `ffprobe` as separate executables for
downloads and MP3 encoding (ADRs 0052 and 0053), which decode these formats.
Running an operation on a converted copy creates a second source of truth:
facts that the copy cannot show, or that FFmpeg changes quietly, could be lost
when the result replaces the original. Checking such facts one by one in each
operation's Replace refusals cannot be complete.

## Decision

Extend the isolated-executable exception of ADRs 0052 and 0053, within
ADR 0013, to decoding. When the native engine cannot open or decode an input,
convert it with the bundled FFmpeg into a staged intermediate in a native
format and run the operation unchanged on that intermediate. FFmpeg never
writes a user's output.

A fallback-backed input never replaces its original. The engine decides this
in one place when it settles an item: the result is always a new file beside
the original, with a warning in Replace mode, and Undo removes only the new
file.

Verify every intermediate against the original with `ffprobe` through one
fixed list of structural facts before the operation runs, and fail the item
on any unexplained difference. Read facts the intermediate cannot show from
the original and report their loss through the existing warnings, plus one
for variable frame timing converted to a constant rate.

Harden every invocation: file protocol only, an explicit demuxer allow-list,
QuickTime external references off, a clean environment, external-reference
checks before and after, a probe time limit, a transcode watchdog that resets
only when output time advances, and live disk-space checks. Classify child
failures as typed errors and keep the native error only when FFmpeg also
rejects the media.

## Consequences

Legacy and broadcast formats can be converted, compressed, trimmed and
extracted, and the original always survives. An intermediate that would
misrepresent the source fails loudly instead of producing a plausible result.
Staging needs disk space proportional to the clip and its profile, and the
conversion adds time before the operation's own work. Re-encodes of
variable-frame-rate sources use a constant grid; the fallback path warns, the
native path still does not. The editor does not use this path. Finder
Preview's Convert and Play uses it only after the button is pressed, for a
throwaway copy, and never for quarantined files.

Alternatives rejected: linking FFmpeg libraries into the app, which ADR 0013
forbids; using FFmpeg as the output encoder, which would bypass the native
writers and their preservation rules; allowing replacement after per-fact
checks, which cannot be proven complete; failing as before.
