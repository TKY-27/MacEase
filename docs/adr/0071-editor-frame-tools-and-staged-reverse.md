# ADR 0071: Editor frame tools and staged reverse

Date: 2026-11-24
Status: Accepted

## Context

The owner asked for saving the frame at the playhead, freeze frames and
reversed segments. The editor's preview is an AVFoundation composition and its
export is MacEase's own timeline encoder; neither can decode backwards.
Backward decoding of long-GOP video multiplies decode work per output frame,
and holding a whole segment in memory is unbounded. A reversed segment must
still work with trims, markup, music, Undo and both save paths.

## Decision

Save Frame renders the edited frame at the playhead through the export's frame
path, including geometry, colour, markup and fades, and writes a Derived image
named `stem_frame_m-ss.mmm` in the thumbnail format from Settings, tone-mapped
to SDR for HDR sources.

A freeze frame is an ordinary segment holding exactly one source frame for 0.1
to 30 seconds of output time, with speed 1× and volume 0; preview scales a
one-frame range and export holds the last frame. Segment output duration is one
shared property instead of hand-written arithmetic.

Reverse renders the segment's source range backwards once into a staged MOV
intermediate: HEVC at quality 0.95 (Main10 for HDR, HEVC with Alpha for alpha),
32-bit float PCM audio reversed sample-exactly, and no frame reordering. The
segment then references the intermediate as an ordinary additional source and
remembers its forward origin, so reversing again restores the forward range,
including trims made while reversed, without encoding. Limit the source range to
60 seconds. Keep at most 256 MiB of decoded pixels per group of pictures in
memory and spill larger groups losslessly compressed to staging on the source
volume. Check free space for the worst case before decoding and refuse with the
required and available amounts. Keep intermediates for session Undo and remove
them when the editor closes. Save reversed edits through the joined export path
as a new H.264 MP4, disclosing flattened transparency and SDR conversion before
saving, and disable Replace Original.

## Consequences

Preview and export need no reverse capability. The cost is bounded and
explained: segments over one minute must be split first. In `docs/spikes.md`,
reversing a 60-second 1080p60 clip with one keyframe went from 713.5 to 45.1
seconds after the spill change, while one-second GOPs went from 28.4 to 40.9
seconds; temporary disk use can approach uncompressed pixels for
incompressible material. Repeated
reversal can retain several intermediates until the editor closes. Reversed
edits cannot replace the original and lose HDR and transparency in the saved
file.

Alternatives rejected: reversing at preview and export time, which needs a
backward-decoding proxy and export path; decoding a whole segment into memory;
re-encoding on every toggle; saving reversed edits through the single-source
path, which cannot reference the staged source.
