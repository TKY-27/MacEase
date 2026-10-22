# 8. In-house codec tuning

Date: 2026-10-20
Status: Accepted

## Context

SPEC.md section 3.8 fixes the algorithms and acceptance metrics of the in-house
encoders. Meeting the metrics needed choices the table does not spell out, and
some of them change what users see.

## Decision

- **Lossy PNG.** Palette distances weight Oklab lightness six times more than
  chroma, because banding in lightness is what the eye and the luma SSIM metric
  notice first. A full-resolution Lloyd pass refines the k-means palette.
  Mapping is not dithered by default; dithering stays available. The writer
  tries no filtering and per-row adaptive filtering and keeps the smaller file.
  The test also bounds the mean Oklab chroma error, so the weighting cannot hide
  color shifts.
- **GIF.** Ordered dithering is the default (Settings > Images > GIF dithering).
  It is stable from frame to frame and met both metrics, while Floyd–Steinberg
  could not be smaller than ImageIO's output at the required SSIM. LZW keeps a
  full code table until compression degrades instead of clearing it at once
  (GIF89a allows this). When dithering is on, the encoder prefers a palette
  entry that extends the current LZW string if it lies within a small RGB
  distance of the dithered target, and diffuses the extra error. This was
  designed from the GIF89a LZW description, without consulting any GPL code.
- **Fixtures.** The photo fixture's grain is mostly luma, like sensor noise.
  The GIF metric runs on frames that went through an H.264 AVAssetWriter
  encode and decode, as SPEC.md section 17 describes.
- **Build.** The `Formats` target is always compiled with `-O`; unoptimized
  numeric codecs are about a hundred times slower and make tests impractical.

## Consequences

- The defaults favor small, stable output; users can still pick
  Floyd–Steinberg for GIF.
- Lossy PNG output has slightly larger chroma error than lightness error, kept
  under 0.02 mean Oklab distance on the fixture.
