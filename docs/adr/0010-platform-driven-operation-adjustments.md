# 10. Platform-driven adjustments to operations

Date: 2026-10-21
Status: Accepted

## Context

Implementing section 8 on macOS 26 and 27 showed places where the platform,
the vendored libraries or the menu model cannot deliver the specified
behavior exactly. Each item below keeps the closest behavior and is tested.

## Decision

- **Video target size (8.10).** VideoToolbox stops lowering the bitrate on
  grainy content well above 0.04 bits per pixel per frame, so a correction pass
  that still misses also steps resolution and frame rate down when settings
  allow it, instead of failing. The correction aims at 96% of the target, the
  middle of the accepted band.
- **LINE preset (9).** Planning has no input duration, so a clip over 300 s
  fails with a message pointing to Trim rather than opening a prefilled Trim
  panel.
- **Archive extraction (8.5).** libarchive's `SECURE_NOABSOLUTEPATHS` rejects
  the absolute staging prefix MacEase extracts into. Entry names and hard-link
  targets are checked before writing (absolute or `..` refuses the archive),
  and `SECURE_NODOTDOT` and `SECURE_SYMLINKS` stay on. `__MACOSX` entries are
  skipped, the archive's quarantine attribute is copied to extracted items,
  and output is capped at the larger of 1 GiB and 1000 times the archive size.
- **Image metadata strip (8.1).** On macOS 27, `CGImageDestinationCopyImageSource`
  keeps EXIF, GPS, IPTC and maker notes in HEIC under every option, so HEIC
  strips re-encode at the settings quality. PNG and TIFF strips write the
  stored pixels with new metadata; decoded pixels stay identical.
- **Image target size (8.10).** AVIF (libaom quantizer steps) and HEIC
  (coarse quality steps) cannot always land within 92% of the target; outputs
  still stay at or under it.
- **Audio compress (8.3).** The in-house MP3 encoder offers 128, 192, 256 and
  320 kbps, so MP3 compression below 128 kbps writes AAC in M4A, the same
  fallback the section uses for lossless sources.
- **Natural-language requests (10).** Plans are one to three menu steps, an
  operation with one of its presets. Steps outside the selected kind or its
  presets are rejected with the reason.
- **Language setting (7).** Changing the language asks before relaunching,
  because running jobs stop.

## Consequences

SPEC.md sections 7, 8.1, 8.3, 8.5, 8.10, 9 and 10 describe these behaviors.
Users of large grainy clips get a smaller frame instead of a failure.
