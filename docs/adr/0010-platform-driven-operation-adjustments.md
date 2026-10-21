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
- **LINE preset (9).** Planning has no input duration, so the compressor
  reports a clip over 300 s and the host then opens the Trim panel. The
  prefilled end sits one second under the limit, because keyframe cuts and
  audio frames can run past the mark, and the compression runs again on the
  trimmed file.
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
- **Video tracks (8.2).** The video pipeline selects the first video and audio
  tracks. Replace operations reject inputs with more than one track of either
  kind before writing. Replacement also rejects skipped subtitles, attachments,
  chapters, data and timecode streams. Derived outputs may use the first tracks.
  Demuxers report skipped streams explicitly; preservation is deferred instead
  of silently removing content. Matroska inputs with unknown-size clusters
  conservatively refuse replacement because later streams cannot be ruled out.
  FLV script events that cannot be regenerated also refuse replacement.
- **Audio auxiliary content (8.3).** Replacements refuse chapters, timed data
  and attachments that the audio writers cannot carry. Preflight checks cover
  MPEG-4 tracks and chapters, ID3 frames, FLAC metadata blocks and PCM container
  chunks. Unrecognized structures fail conservatively before writing; ordinary
  descriptive tags retain the existing selected-tag policy. Full auxiliary
  content remuxing is deferred.
- **Language setting (7).** Changing the language asks before relaunching,
  because running jobs stop.
- **Chained Ogg (8.3).** Multiple logical streams in sequence are unsupported.
  The reader scans pages before decoding and rejects a new logical stream
  after EOS with a typed invalid-input error. No output is written and the
  original is kept. Multiplexed logical streams also fail during this preflight
  so replacing audio cannot discard another stream. Multi-stream decoding is
  deferred.
- **Audio layouts (8.3).** Replacement never silently downmixes. Unsupported
  layouts fail before writing. The current MP3 and Opus implementations are
  limited to mono and stereo. Opus multistream support requires changes to
  its codec and Ogg mapping implementation and is deferred. AAC output is
  limited to six channels; raw ADTS refuses quadraphonic layouts because its
  channel configuration would describe different speakers. Unknown source
  layouts are rejected. Recognized layouts are converted to canonical PCM
  speaker order; 5.1 accepts MPEG layouts A, B, C and D.
- **Video alpha (8.2).** Resize, flip, frame-rate changes and exact trim keep
  alpha through HEVC with alpha or ProRes 4444 in MOV, and VP9 in WebM.
  Other containers reject alpha re-encodes before writing. Stream-copy paths
  preserve alpha when the destination can carry it. HEVC and ProRes alpha
  require an AVFoundation source format description; custom containers support
  VP9 alpha through BlockAdditions.
- **AVI index budgets (13).** Duplicate and overlapping OpenDML references
  are rejected before reading their chunks. Total index reads cannot exceed
  the file size or 128 MiB; total records cannot exceed the file size divided
  by the entry width or 4,000,000. At most 65,536 OpenDML references are
  accepted. These bounded checks and cancellation prevent amplified reads
  and keyframe allocation without redesigning the demuxer.

## Consequences

SPEC.md sections 7, 8.1, 8.2, 8.3, 8.5, 8.10, 9, 10 and 13 describe these behaviors.
Users of large grainy clips get a smaller frame instead of a failure.
