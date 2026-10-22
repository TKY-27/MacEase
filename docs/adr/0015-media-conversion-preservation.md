# 15. Native media conversions and sequence preservation

Date: 2026-10-21
Status: Accepted

## Context

The Finder catalog omitted existing ALAC extraction and CAF encoders. PSD,
AIFF-C, TGA, and PDF-to-TIFF paths also lacked classification or orchestration.
Image conversion selected the first frame or page for incompatible targets,
contradicting section 8.13, and reduced finite animation loops to a Boolean.

## Decision

- Expose existing M4A ALAC extraction and CAF PCM/ALAC conversion directly.
  Classify AIFF-C and let the existing AudioToolbox decoder validate its codec.
  Do not maintain a second codec allowlist or container parser.
- Decode PSD through ImageIO's stored composite. Offer PNG, JPEG, and TIFF
  exports with a flattening warning. Always retain the layered source. Refuse
  JPEG when the composite has transparency; do not silently fill it.
- Decode and encode TGA through ImageIO. Probe both advertised capabilities
  before publishing its destination. macOS 26 device acceptance remains open.
- Render PDF pages through the existing PDFKit renderer into one ImageIO TIFF.
  Honor saved DPI and printing permissions. Verify page count and always retain
  the PDF. Cap aggregate raster storage before rendering or opening a writer,
  using the existing retained-image budget of 250 MB including overhead.
- Refuse targets that cannot retain every animation frame or TIFF page before
  writing. Keep loop counts through ImageIO, GIF, and WebP encoders; refuse
  counts that exceed the target field. Preserve an absent GIF loop extension.
  Refuse unverified multi-image sequence types rather than selecting one image.
- Keep the existing staging, output verification, metadata checks, collision
  handling, and recoverable commit paths. Add no native dependencies.

## Consequences

New menu leaves run immediately. Users receive clear refusals instead of partial
images, and composite exports retain the original PSD. The PDF raster cap is a
bounded implementation guard, not a measured bound on framework memory use.
Codec availability is validated on each host; advertising a format alone does
not prove representative-file correctness on every supported OS version.
