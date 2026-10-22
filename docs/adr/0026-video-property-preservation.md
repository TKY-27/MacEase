# 26. Video property preservation

Date: 2026-10-22
Status: Accepted

## Context

Compression omitted alpha encoder settings. Ordinary video edits decoded to
8-bit pixels and unconditionally tagged outputs as BT.709. Metadata and track
attribute copying only ran during explicit HDR-to-SDR conversion.

## Decision

- Apply ADR 0019's resolved-mode policy to video properties. Preserve them
  when supported, disclose conversion in new-file mode, and refuse before
  staging in Replace. Always-Derived audio, animation and background exports
  remain new-file work regardless of the saved setting. Container conversion
  remains a Transform under section 3.5.
- Generic alpha compression uses HEVC with alpha in MOV or VP9 with alpha
  in WebM. Explicit platform constraints remain binding. Opaque targets
  composite onto the configured video rotation background and warn.
  Every bitrate, resolution and frame-rate retry shares this preflight.
  Arbitrary-angle rotation leaves added canvas transparent when the encoder
  preserves alpha, without compositing away source transparency.
- Preserve BT.2020 PQ/HLG with 10-bit decoding and HEVC Main10. Carry
  primaries, transfer, matrix, mastering-display and content-light metadata
  through VideoToolbox. Use CoreMedia parameter-set reconstruction for HEVC
  descriptions from custom containers instead of writing a bitstream parser.
  Reopen encoded outputs before commit and compare their HDR properties to
  the source; reject omissions introduced by the output writer.
- HLG accepts absent mastering-display and content-light metadata. Disable
  automatic Dolby Vision generation for HLG encoding. Leave PQ static metadata
  insertion and verification intact.
- Treat Dolby Vision 8.4 as an HLG-compatible base layer with unsupported
  dynamic metadata. New-file edits retain HLG Main10 when the target allows
  it and warn `dolbyVisionRemoved`. SDR targets additionally warn
  `videoToneMappedToSDR`. Replace refuses before staging. Copy-based edits
  re-encode rather than retain stale RPU metadata. Verify the HLG configuration
  independently of the source Dolby Vision record. Reject other profiles,
  mixed Dolby Vision and non-Dolby Vision formats, and other unsupported
  dynamic metadata.
- Detect Matroska/WebM Colour transfer and static HDR fields before decoding.
  Refuse container-side HDR metadata until that backend can carry or safely
  tone-map it. This bounded guard also covers VP9 HDR and stream copies;
  HEVC signals contained entirely in parameter sets remain supported.
- SDR-only targets use the existing AVFoundation HDR-to-SDR decoder and
  warning/refusal policy. Unsupported HDR layouts, dynamic metadata and
  unsupported tone-mapping decoders retain typed refusal. No approximate HDR
  conversion or unverified metadata fallback is introduced.
  Thumbnails share animation exports' tone mapping and warnings, and always
  keep the original under either saved output mode.
- Share metadata and track-attribute copying across native MOV/MP4/M4V
  outputs. Preserve supported language in Matroska/WebM. Reconstruct only
  complete alternate groups supported by AVAssetWriter. Warn or refuse
  present properties the selected output writer cannot store.
- Ignore singleton alternate groups and software or encoding-tool tags in
  loss detection. Keep encoder attribution, titles, descriptions, locations,
  creation dates and other user metadata in the preservation contract.
  Detect Matroska/WebM Info Title and Tags SimpleTag entries, including
  track-targeted tags and TrackEntry Name. LanguageBCP47 overrides legacy
  Language regardless of element order and participates in language loss checks.
  Carrying these names and tags is unsupported, so new-file results
  warn and Replace refuses before staging. MuxingApp and WritingApp are
  provenance, not user metadata.
- MOV retains QuickTime ISO6709 locations. MP4/M4V conversion can insert
  zero altitude where the source has none; keep coordinates with a warning
  in new-file mode and refuse Replace before staging. Compare native output
  properties before commit to detect other writer omissions or normalization.
  Explicit SDR conversion shares these metadata checks while permitting
  the requested HDR removal.
- Read Matroska/WebM display dimensions, units and pixel cropping, plus native
  clean aperture and pixel aspect ratio. Matroska/WebM copies retain original
  container fields and map representable native display dimensions and crop.
  Native copies retain representable clean aperture and pixel aspect.
  Apply crop before display aspect and requested geometry during re-encoding
  and image exports. Pixel units use
  declared dimensions; physical and ratio units use the cropped height and
  declared ratio. Unknown units and unsupported destinations use the existing
  track-metadata warning or replacement refusal before staging. Reopen copies
  to verify the retained geometry before commit.

## Consequences

The original-file, stream-count, staging, cancellation, Trash and Undo
contracts remain unchanged. No dependency is introduced. Regression tests
inspect decoded alpha, x265 PQ/HLG outputs, SDR-only target policy and native
metadata/track attributes. HDR display quality still requires device viewing.
