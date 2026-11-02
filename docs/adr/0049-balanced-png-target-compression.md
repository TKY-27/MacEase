# 49. Balance PNG target quality, resolution and latency

Date: 2026-11-02
Status: Accepted

## Context

After requesting website-like latency, the owner explicitly permitted quality
and resolution reductions when substantial size savings require them, giving
4K-to-1080p as an example. The owner asked for balance and warned against
unnatural images caused by overcommitting to quality preservation.

The prior exhaustive target search tried maximum DEFLATE effort before every
palette or resolution reduction. A 48 MP photograph still took 26.864 seconds
after exact-pixel memory improvements. An isolated balanced-only experiment
took 10.193 seconds but retained 64 colors and reduced dimensions another step.
The same effort change reduced a gradient to 5.311 seconds with identical
output. These experiments were not adopted directly.

The first balanced target prototype took 2.1–5.1 seconds across six 24/48 MP
sentinels, but direct crop review found magenta/green patches in alpha and
gradient stress images. Its global mean chroma scores did not establish natural
output. GIF dithering had leaked into PNG defaults contrary to ADR 0008;
isolating that setting improved alpha precision but did not remove the patches.
An isolated lightness-weight reduction from six to two still produced patches
and failed the unchanged photo SSIM gate (0.960508 versus 0.97). Reject that
change and preserve the shared GIF/SVG metric.

For context, iLoveIMG's default compressor reduced the same public photograph
from 69,326,537 to 17,385,491 bytes at the original 8000 × 6000 dimensions,
using 59 palette colors. It did not reach the 10 MB target. Its observed
52–69-second completion interval includes upload/network time and is not a
local codec timing comparison.

## Decision

For static 8-bit RGB PNG target compression, use balanced native effort and
try lossless output followed by 256 colors at the original dimensions. If
oversized and downscaling is permitted, use the actual encoded size to estimate
the next scale as
`sqrt((0.95 × targetBytes - fixedBytes) / (actualBytes - fixedBytes))`,
with a positive payload budget and 5% headroom. Reuse the measured candidate's
PNG chunk overhead so a small target does not incorrectly scale metadata.
Retain 256 colors and allow at most three measured scale corrections. This
favors natural color transitions at a useful smaller resolution instead of
forcing a very small palette at every larger resolution.

Before accepting palette reduction, inspect at most 8 × 8 uniformly spaced
native-resolution Gaussian 11 × 11 windows from the existing pixels, palette
and indices. Require mean luma SSIM of at least 0.97 on both black and white
composites and mean Oklab chroma error of at most 0.02 in every window. Do not
downsample the quality reference or decode another full image. If a candidate
fails, permanently switch that item to balanced lossless RGB/RGBA for its
current and subsequent scales. Reuse the actual-size scaling rule and the
three-correction bound. Keep the independent full-image test oracle and
thresholds. Full-color resizing can sacrifice more spatial detail but avoids
accepting the reproduced color patches. Report actual changes only.

PNG uses no dithering by default; only GIF reads the GIF dithering setting.
Verify setting isolation through actual decoded PNG and GIF output.

If downscaling is disabled, never alter dimensions. After the balanced lossless
attempt, retain the existing bounded 256/128/64-color search with strong
compression fallback and apply the same palette quality checks. A previously
reachable target can now fail when its palette fails those checks.
Do not precede it with redundant oversized planning candidates.
Preserve the existing precision/HDR, non-RGB and animation
paths. The source, ICC, metadata and alpha contracts remain in force. Planning
outputs may exceed the target but must stay within existing working/encoded
limits and be released before the next candidate. Publish only the independently
verified fitting output. Exhausted attempts fail explicitly and preserve the
original; no minimum-size estimate triggers another search.

This supersedes the exhaustive maximum-effort and fixed-resolution-step
ordering in ADRs 0045 and 0046, and the unresolved quality-tradeoff restriction
in ADR 0048. The owner authorized this policy change; no new effort-mode UI or
format conversion is introduced. Report palette and dimension changes through
the existing item results.

Non-target PNG quality presets also use balanced native effort. Keep their
selected palettes and decoded pixels unchanged; encoded bytes can increase
slightly. The existing output-not-smaller check still applies. Conversion
remains lossless and target candidates retain their quality checks.

## Consequences

Candidate bytes and dimensions can differ from earlier versions. Acceptance
uses actual target attainment, natural colors, text/edge quality, transparency,
preserved metadata/precision, cancellation and source safety. Compare matched
Release measurements and inspect outputs; do not claim identical quality or
few-second completion without evidence. Existing memory bounds and the owner's
approximate resident-memory acceptance continue to apply.
