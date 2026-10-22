# 19. Image property loss and occupied output names

Date: 2026-10-21
Status: Accepted

## Context

Ordinary image conversion silently flattened transparency and discarded HDR
gain maps outside JPEG/HEIC. Refusing all such conversions would also reject
ordinary photos in the default new-file mode. Name selection followed symbolic
links, so a dangling link could cause the commit loop to retry one name forever.

## Decision

- Resolve preservation against the actual commit mode. Always-Derived exports
  retain that behavior when Replace is selected.
- Inspect actual alpha samples, including high-precision alpha. An opaque
  alpha channel is not transparency loss. JPEG/BMP outputs use the existing
  custom background setting, default white, and report a typed warning when
  flattening. GIF and traced SVG apply the same policy to partial alpha;
  their binary transparency cannot retain it. Replace refuses before writing
  and suggests Save as New File.
- Inspect gain maps, PQ/HLG transfer functions and content headroom across
  every frame/page. Wide gamut and bit depth alone do not prove HDR.
- When the output path cannot preserve HDR, new-file operations share the
  Convert > SDR decoder and tone mapper, remove obsolete HDR signalling, and
  report a typed warning. Replace refuses and suggests Save as New File or
  Convert > SDR. Never discard the map and encode the default base alone.
  Alpha flattening changes the base pixels, so it also tone-maps before
  compositing instead of reattaching the old map to a different background.
- Keep JPEG/HEIC gain-map preservation and its existing calibration checks.
  Direct full-depth PNG/TIFF conversion verifies native HDR profile and depth
  after encoding. Other native-HDR edits use the explicit loss policy until
  their preservation paths are verified. Unsupported gain-map decoding keeps
  the existing typed refusal rather than guessing calibration.
- Keep frame timing and bounded animated decoding. Account for retained
  images and tone-mapping or alpha-inspection buffers before allocation.
  Inspect encoded raster SDR outputs before commit. Display quality and peak
  resident memory still require the existing device acceptance checks.
- Treat every existing directory entry as occupied using `lstat`, including
  dangling links. Advance the candidate number before attempting the move;
  collisions never retry the same candidate. Check cancellation during naming.

## Consequences

SPEC sections 3.5, 8.1, 8.12 and 8.13 now distinguish disclosed new-file
property loss from forbidden replacement loss. This supersedes the blanket
requirement for an explicit prior SDR conversion and the PSD-to-JPEG
transparency refusal. Existing original-file, Trash, Undo, sequence-preservation
and allocation limits remain in force. No new dependency is introduced.
