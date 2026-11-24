# ADR 0077: Forbid external media references

Date: 2026-11-24
Status: Accepted

## Context

QuickTime reference movies can point AVFoundation at media in other files,
including files outside the folder the user chose. MacEase opens media from
Finder, from archives, in the editor and in Finder Preview, often for files the
user has not inspected. With references allowed, a selected movie could make
MacEase read, convert or display content from unrelated locations. Restricting
references only in Finder Preview would leave the same files readable through
every operation.

## Decision

Create every `AVURLAsset`, `AVPlayer` and `AVPlayerItem` in the engine and the
app through one constructor that sets `AVURLAssetReferenceRestrictionsKey` to
`AVAssetReferenceRestrictions.forbidAll`, for restricted and unrestricted files
alike. Before `AVAudioFile` entry points (audio jobs, preview sources,
waveforms, enhancement), reject files that contain external references through
the same helper. Map the forbidden-reference error to one typed engine error,
`externalMediaReference`, with one English and Japanese message that tells the
user to export a self-contained copy. Propagate every other error unchanged.

## Consequences

Reference movies are refused in conversion, compression, the editor,
thumbnails, animation export, Audio Trim, archive browsing and Finder Preview,
including Convert and Play. This is an accepted compatibility change: users must
export a self-contained copy first. A single constructor makes a new entry point
that forgets the restriction visible in review and searchable.

The first security round restricted only Finder Preview's assets; it was
extended to every entry point because the same files stayed readable through
ordinary operations.
