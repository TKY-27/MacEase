# ADR 0075: Consent for omitted streams and native MOV timecode

Date: 2026-11-24
Status: Accepted

## Context

Transforms refused every input holding content the pipeline cannot carry over,
such as timecode, subtitles, chapters, attachments or data tracks. Ordinary
camera and editing-app MOV files carry a timecode track, so common compression
and conversion failed with no way forward, while silently dropping the content
would violate the rule that no stream loss is silent. Consent must not outlive
the file the user looked at, and it must not let one approved kind discard
another.

## Decision

Replace the refusal with a question. The engine still stops an item before
writing and names every kind it would leave out. Ask after a Finder-started run
in Activity, and before running in the editor's open and Add Videos… sheets,
Audio Trim, Finishing Recipes and Audio Enhancement. Present the question as a
question, never as a failure, with every affected file, a plain sentence per
kind and what happens to the originals. Record consent per file as the
identity-bearing stamp taken before inspection together with the kinds that
file reported, and apply it only while the file still matches. Resubmit only
the affected files, once per result, and keep Retry Failed for real failures.
Report every omission on the result.

Carry AVFoundation-readable timecode natively in timing-preserving MOV outputs,
in the same AVAssetWriter session as the video. Validate every real sample
before encoding, reproduce payloads, format descriptions and timing exactly,
skip zero-sample markers, use the least common multiple of the movie and
timecode scales, and tolerate only a track-duration difference strictly below
one source movie tick caused by the source's own rounding. Verify the output
after encoding. Any shape outside these rules, and the rare mismatch found
after encoding, falls back to the consent question; writer, read, file-system
and source-change failures keep their own errors.

## Consequences

Files with timecode, subtitles or chapters can be processed after one explicit
choice, and the default never loses content. Replacing a file during a question
invalidates the consent. MOV timing-preserving outputs keep valid timecode;
MP4, M4V, timing-changing edits and clipped timecode edits still ask. Chained
Ogg remains refused. Multiple video or audio tracks in transforms still refuse
before writing. Measured timecode replay behaviour, including the clipped-edit
limitation, is in `docs/spikes.md`.

Alternatives rejected: keeping the refusal; remuxing the writer's output with the bundled
FFmpeg or transplanting timecode atoms after encoding, which added a second
writer and could not be verified sample by sample; regenerating timecode from a
start value; relaxing the comparison for edited timecode, whose native replay
changed real sample durations and sometimes the visible range.
