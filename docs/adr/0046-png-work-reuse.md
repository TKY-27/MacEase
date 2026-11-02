# 46. Reuse PNG work without changing search priority

Date: 2026-11-02
Status: Accepted

## Context

The owner rejected publishing candidate 5 with the recorded latency and resident
memory misses. Preserve quality and continue until the existing criteria pass.
Profiling the same 48 MP photograph found repeated filtering and native
compression dominated runtime. Histogram and palette lookup were comparatively
small. Completing a valid compression still requires every higher-priority
lossless, palette and resolution attempt to precede the selected result.

## Decision

Prepare filtered lossless rows once for balanced and maximum compression.
Specialize the PNG filter loops and accumulate their existing signed-byte scores
while writing each row. Preserve predictors, tie order, row framing and
cancellation checks. Exact filtered-byte comparison covers all filters, supported
component layouts, packed depths and first-row boundaries.

Allow the lowest-priority palette to run its two maximum-effort filter attempts
concurrently when the existing frame-memory budget permits. Await the `none`
result before accepting `adaptive`; retain the existing palette and resolution
priority. Higher-priority palettes keep one filtered workspace at a time. Avoid
caching two full filtered images for a serial attempt merely to save a cheap
filter pass. Structured children finish before their storage is released.

Charge both active compression outputs and both serialized outputs, retained
images, shared RGBA pixels and raster/filter scratch to the unchanged 1 GB
working budget. Opaque serial palette work reserves 16 MB auxiliary space;
alpha work or two concurrent native compressors reserve 32 MB. With the pinned
libdeflate build, per-instance allocation probes report 668,295 bytes at level 6
and 9,011,751 bytes at level 12. Palette-analysis temporaries leave scope before
native compression. These bounds do not replace actual full-app RSS acceptance.

Use Foundation's `ContiguousBytes` for internal PNG raster storage, supporting
the existing shared byte arrays and mapped palette indices. Draft and final
palette mappings use the same mapping loops with caller-owned storage; GIF
keeps its array-returning interface. For opaque RGB output, share original RGBA
samples and gather RGB into two alternating row buffers. This removes the
full-frame RGB intermediate instead of merely releasing it sooner. Sampling
uses the source row width while output framing uses the encoded row width.
Access raw pointers only inside the storage closure. No public pixel
buffer, precision conversion, codec, palette, metadata or format policy changes.

For target-size compression, also read premultiplied RGB images directly only
when they have 8-bit integer components, a supported byte order, no decode
array and alpha 255 at every pixel. Retain the provider through all raw reads,
check cancellation during both scans, and preserve its original color space.
Keep the existing six-copy preflight for this path. Partial alpha, unsupported
layouts and greater precision keep the previous ImageIO path. Independent
fixed-pixel and actual Core Image scaled-image tests compare the old PNG round
trip for pixels, profile, depth and metadata. This removes intermediate PNG
encoding and decoding without changing the candidate's quality.

The row-scratch architecture was informed by the pinned MIT-licensed Oxipng
source. The RGBA adapter is an independent implementation, not an upstream
function translation. No Oxipng source is bundled. A reviewed PNGoptim parallel
DEFLATE implementation retains multiple partition buffers and does not solve
the measured RSS peak. Its quantizer's documented comparison/alignment with
libimagequant also leaves provenance uncertainty under ADR 0013, so that code
is not copied or translated.

Return a prefix view of mapped compressed bytes while retaining the complete
mapping owner. Allocate final PNG serialization once at its exact size and
release all mappings through their original allocation lengths. This replaces
the compressed-result heap copy in ADR 0045. A separate lifetime probe verifies
partial views, live ownership, copy-on-write and full mapping release.

## Consequences

The selected output must remain identical to the prior search. Independent
ImageIO decoding and fixed source pixels verify the maximum-filter success,
failure and metadata paths, alongside the existing original-protection tests.
Timing and RSS remain measured acceptance requirements. An intermediate
25.296-second photograph run preserved the exact output but exceeded resident
memory; it is evidence for further work, not release acceptance.

## References

- [Foundation ContiguousBytes](https://developer.apple.com/documentation/foundation/contiguousbytes)
- [Foundation Data unmapping](https://developer.apple.com/documentation/foundation/data/deallocator/unmap)
- [Oxipng row filtering, pinned source](https://github.com/oxipng/oxipng/blob/7d2fb92e0e83bbffb1e7394a856a4026ffac069c/src/png/mod.rs)
- [Oxipng MIT license](https://github.com/oxipng/oxipng/blob/7d2fb92e0e83bbffb1e7394a856a4026ffac069c/LICENSE)
- [PNGoptim parallel DEFLATE, pinned source](https://github.com/okooo5km/pngoptim/blob/91cd711fb7b7e69b30741483cbac1175b7d16e9e/src/deflate.rs)
- [PNGoptim quantizer provenance notes](https://github.com/okooo5km/pngoptim/blob/91cd711fb7b7e69b30741483cbac1175b7d16e9e/docs/phase-d/REFERENCE_DIFF_ANALYSIS_V2.md)
- `docs/v2.1.0-validation.md`
- `build/v2.1.0/png-perf/latency-profile/`
- `build/v2.1.0/png-perf/filter-probe/proof.json`
- `build/v2.1.0/png-perf/native-allocation.log`
