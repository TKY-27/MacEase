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
- **HDR gain maps (3.5, 8.1).** Keep both ISO 21496-1 and Apple auxiliary
  types for JPEG/HEIC outputs. Flip, right-angle rotation, resize, border
  trimming, preset crops and compression resizes transform the map using
  the base image's geometry at the map's resolution. Preserve calibration
  metadata and verify encoded dimensions, representative pixel values and
  calibration tags. Metadata stripping keeps gain-map calibration.
  Support interleaved 8-bit monochrome, RGB, RGBA and BGRA maps. Each source
  and output map raster is capped at 64 MiB before transformation allocation;
  encoded-map buffers also count toward the encoder workspace budget.
  Other raster layouts and advertised maps that ImageIO cannot retrieve fail
  with `imageGainMapUnsupported`. Background replacement and added canvas
  pixels, including non-right-angle rotations and letterbox presets, fail
  with the same error because a neutral encoded gain cannot be inferred from
  arbitrary calibration safely. Full HDR recompositing and additional raster
  layouts are deferred. Removing Apple maker notes also refuses replacement
  when an Apple gain map is present because those notes can carry HDR
  calibration. Original files remain untouched on refusal.
- **Image target size (8.10).** AVIF (libaom quantizer steps) and HEIC
  (coarse quality steps) cannot always land within 92% of the target; outputs
  still stay at or under it.
- **Audio compress (8.3).** The in-house MP3 encoder offers 128, 192, 256 and
  320 kbps, so MP3 compression below 128 kbps writes AAC in M4A, the same
  fallback the section uses for lossless sources.
- **RF64 and BW64 input (8.3).** AVAudioFile on macOS 27 reads generated
  PCM RF64 and BW64 fixtures natively, including the `data` size sentinel.
  Keep that decoder. Recognize both signatures and interpret the mandatory
  first `ds64` chunk's 64-bit RIFF size, audio size and optional chunk-size
  table during replacement preflight. Cap the table at 4,096 entries before
  accumulation and check cancellation while reading it. Reject missing or
  invalid sizes and out-of-file ranges before writing. Auxiliary content
  refusal still applies.
- **Encrypted PDFs (8.6).** Common opening rejects `isLocked`, not
  `isEncrypted`. Owner-password-only PDFs can open unlocked while remaining
  encrypted. Derived page images require `allowsPrinting`; Derived text,
  merge, page extraction and split require `allowsCopying`. Compress and
  rotate keep refusing encrypted inputs to avoid losing protection.
- **Edited video presets (9).** Resolve the container from `formats`, keeping
  a listed source or choosing the first entry. Honor the selected video and
  audio codecs throughout compression, including target-size retries and
  stream-copy candidates. Accept MP4, MOV and M4V with H.264 or HEVC and AAC;
  WebM with VP9 and Opus; and MKV with H.264, HEVC or VP9 and AAC or Opus.
  Reject unsupported tuples in Settings, preset persistence and execution.
  Omitted formats default to MP4 and omitted codecs to H.264 and AAC.
  WebM requires explicit VP9 and Opus selections.
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
  speaker order; 3.0 accepts MPEG A and B, and 5.0/5.1 accept MPEG A, B,
  C and D, including the AAC tags emitted by the engine. Quadraphonic AAC
  remains supported. Center-surround AAC 4.0 is a different speaker set and
  remains rejected before decoding or writing. On the verification Mac,
  AVAudioFile opens a genuine AAC 4.0 input but refuses PCM reads, and AVAssetWriter silently
  emits quadraphonic AAC when requested to write AAC 4.0, losing a center-only
  signal. Supporting that layout requires a different codec path; accepting
  its tag alone would lose audio. Normalization validates layout before its
  analysis pass as well as before replacement.

  The AAC 4.0 regression fixture is a one-second, 48 kHz center-only tone,
  generated using the installed FFmpeg executable without reading its source:

  ```sh
  ffmpeg -f lavfi -i 'aevalsrc=0|0|0.2*sin(2*PI*440*t)|0:s=48000:d=1:channel_layout=4.0' -c:a aac -b:a 384k ffmpeg-aac-40-center.m4a
  ```

  The checked-in fixture SHA-256 is
  `76271691bdc84e68be035ba01d5ac552394f9ac6fe72c487576e9dc0fc5416d8`.
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
- **Image decode budgets (8.1, 8.6, 13, 16).** The previous global 100 MB
  cap rejects ordinary 48 MP camera images. The revised budget separates a
  frame's size, retained frames and an operation's working buffers. Of the
  1.5 GB resident target, 500 MB is reserved for frameworks and 1 GB for
  explicit buffers. Dimensions are checked before decoding, with aligned rows
  and actual decoded strides checked separately. The allocation estimates
  are as follows. They require Instruments validation for resident memory.

  | Path | Explicit buffers charged |
  | --- | --- |
  | Still decode and output verification | One frame, at most 1 GB |
  | Retained TIFF and image-to-PDF | Up to 250 MB, reserving four sets for originals, transformed frames, pixel conversion and encoder output |
  | Animated image edits | One decoded frame per step, plus bounded decoder, transform and streaming-writer buffers; completed frames do not accumulate |
  | Core Image and bitmap geometry | Source plus destination, using their separate dimensions and depths |
  | Border detection | Retained images plus provider bytes and RGBA pixels |
  | ImageIO encode | Retained images plus one output-sized buffer, plus one flattening canvas for opaque formats |
  | Background replacement | Retained images plus four RGBA-equivalent buffers for converted pixels, coverage, mask provider and compositing |
  | SVG tracing | 100 MB RGBA-expanded source cap, plus the encoder workspace check |
  | WebP, JXL and GIF | Retained images plus three RGBA-equivalent buffers for pixel conversion, codec working pixels and output |
  | AVIF | Retained images plus four RGBA-equivalent buffers for pixel conversion, mutable RGBA, YUV and output |
  | Quantized PNG | Retained images plus three RGBA-equivalent buffers for pixel conversion, palette rasters and filtered output |
  | Optimized lossless PNG | Retained images plus six RGBA-equivalent buffers for decoded pixels, provider bytes, RGBA pixels, candidate rasters, filtered samples and encoded output |
  | PDF rendering and lossless metadata rewrite | Three buffers, at most one third of 1 GB each |
  | SVG | Two encoded copies plus three rendered buffers |
  | Video animation export | Existing 32 MB output-frame cap and streaming encoder; completed frames are released |

  PNG conversion preflights both the optimized and ordinary lossless paths.
  If only optimization exceeds the budget, conversion uses ordinary lossless
  ImageIO encoding and reports `pngOptimizationSkipped`. This defined fallback
  keeps pixels and dimensions unchanged. A request that also exceeds ordinary
  encoding's workspace still fails with the typed memory error. Target-size
  PNG compression reports the same warning and tries palette candidates if
  only lossless optimization exceeds the budget.

  Animated GIF, APNG, WebP and HEICS inputs use a reusable ImageIO source.
  Resize, rotate, flip, conversion, metadata stripping and compression feed
  each decoded frame to the output writer and release completed frames.
  Border trimming first scans every frame for the union of content bounds.
  Compression retries decode again, retaining timing summaries rather than
  pixels. GIF uses the existing streaming writer with per-frame palettes;
  APNG uses an ImageIO destination and WebP uses bounded encoding chunks.
  WebP payload accumulation uses the 250 MB encoded-byte budget and fails
  with the existing memory-limit error when exceeded.
  This removes the retained-animation cap without increasing frame limits.
  HEICS output remains unsupported and fails explicitly; HEICS input can
  be converted to a supported animated format without dropping frames.

  Encoders also charge distinct retained source images supplied by transforms
  and compression plans. No frame budget grows with pages already exported
  by PDF-to-images or recognized by PDF OCR. PDF-to-images drains an
  autorelease pool per page. Images-to-PDF still retains its inputs and keeps
  a cumulative cap.

  ICO still rejects shared or overlapping payloads before decoding and keeps
  only its largest fallback representation. ICNS retains sequential traversal.
  Both icon readers keep their 100 MB cumulative decoded-pixel and entry
  accounting cap. Eager encoded input has a separate 250 MB cap, a quarter
  of the explicit working budget, allowing real large PNG files while leaving
  space for input copies and icon decoding. ImageIO reads ordinary stills
  from URLs instead of eagerly copying their entire encoded input.

  A single 200 MP 8-bit RGBA source fits the individual-frame budget, but two
  full-resolution copies already consume 1.6 GB. Full-resolution 200 MP
  conversion, geometry, border detection, compression and OCR are not accepted
  as complete coverage by this change. Tiled transforms and streaming codecs
  are required to satisfy that request under section 16. This bounded repair
  rejects oversized workspaces with the existing typed error rather than
  increasing the resident target or silently reducing resolution.
- **Video display transforms (8.2, 13).** Re-encoding applies all eight
  right-angle rotation and reflection combinations to pixels. Copies keep the
  source display matrix only in containers that support it. Source matrices
  containing shear, scaling or non-right-angle rotation are refused before
  replacement. Arbitrary rotations explicitly requested by the user still
  work. Supporting other source matrices is deferred.

## Consequences

SPEC.md sections 7, 8.1, 8.2, 8.3, 8.5, 8.6, 8.10, 9, 10 and 13 describe these behaviors.
Users of large grainy clips get a smaller frame instead of a failure.
