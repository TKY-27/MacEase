# 53. Audio preservation and editing stability

Date: 2026-11-05
Status: Accepted

## Context

The owner reported degraded MP3 extraction and crashes while trimming video,
requested shared precise audio/video timeline controls and a complete behavior
audit, and later added download UI and TikTok failure investigation. Crash logs
identify nested Swift exclusive access. Controlled MP3 comparisons show greater
error in the former encoder; the reported music file is not yet available.

## Decision

Implement SPEC section 23. Add explicit original-audio packet extraction without
encoding fallback. Replace local MP3 encoding with the already bundled isolated
LGPL FFmpeg/libmp3lame process, extending ADR 0052 only for this use. The owner
approved this provided original application code retains MIT. No LGPL code is
copied or linked into the app. Preserve notices and matching source distribution.

Use a shared precise timeline with yellow ranges, anchored zoom, silent skimming,
snapping, waveform display and one Undo per gesture. Publish complete state values
after mutation. Preserve supported existing editor behavior. Audit actual
operation results rather than treating passing unit tests as complete UI proof.

The owner explicitly changed delivery to push only. Do not tag, publish a
release, change the public download site or increase the release version.

## Consequences

Local MP3 output now requires the existing pinned runtime. It remains offline,
streams PCM and shares cancellation/file safety. MP3 is still lossy; original
extraction is the preservation path. Unsupported lossless copies fail explicitly.
New shared timeline behavior needs real input/rendering and model regressions.
