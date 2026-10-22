# 12. Gain-map calibration and raster decoding

Date: 2026-10-21
Status: Accepted

## Context

On macOS 27.0.1 with Xcode 27.1, all four generated HDR JPEG edit cases
failed after encoding. Their dimensions and `L008` samples were supported.
The ISO `HDRToneMap:ChannelMetadata` array contains opaque metadata tags;
`CFEqual` compares those objects rather than their nested calibration values.

Core Image's RGB ISO output exposes another platform boundary. ImageIO
returns `420f` dimensions, metadata and color space, but omits the auxiliary
data bytes. Core Image can decode that auxiliary image. ImageIO accepts a
packed `24RGB` auxiliary raster for both JPEG and HEIC; attaching `32RGBA`
instead fails finalization on this platform.

## Decision

- Compare calibration recursively through tags, structures, arrays and
  qualifiers. Preserve ordered channel arrays and reject changed values or
  missing calibration.
- Decode ISO `420f` and `444f` auxiliary images with Core Image when reading
  the source, with orientation application and color management disabled.
  Pack the rendered RGB channels into an ImageIO `24RGB` payload while
  retaining calibration and color space. Use the same read path when
  verifying the encoded output.
- Resolve explicit auxiliary orientation before inherited base orientation.
  Normalize orientation tags after transforming map samples.
- Verify monochrome samples pointwise. For RGB, compare mean absolute error
  in a 3-by-3 neighborhood at each sample location, keeping the 16-level
  per-channel bound. Chroma interpolation changes individual edge pixels;
  averaging absolute errors does not cancel opposite signed errors.
- Keep the existing raster allocation bounds and undefined-canvas refusal.
  This extends ADR 0010's bounded raster support without dropping HDR.

## Consequences

- Ordinary Apple monochrome and ISO monochrome/RGB maps use the same geometry
  transformations and output verification.
- Lossy re-encoding may change samples within the existing tolerance;
  calibration values must still match.
- Generated integration fixtures exercise JPEG and HEIC through documented
  Core Image and ImageIO APIs. Platform behavior is recorded in `spikes.md`.
