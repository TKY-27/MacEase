# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Original-audio extraction that ignores bitrate settings and refuses implicit conversion.
- Shared yellow video/audio trim ranges, silent skimming, committed playheads,
  zoom gestures and keyboard controls, snapping and session Undo/Redo.
- Progressive audio waveforms and app-hosted trim regression tests.
- Typed `m:ss.sss` trim boundaries and a resizable dark audio trim window.

### Changed

- Stream all local MP3 output through isolated FFmpeg/libmp3lame, retaining
  CBR/VBR controls and independent decoding and quality tests.
- Align download controls and show actual source video dimensions, excluding storyboards.
- Redesign the photo/video editor like familiar editing apps: dark workspace,
  unified toolbar with centred tools, a transport bar under the viewer,
  a taller filmstrip timeline and an inspector grouped into Light, Color and Detail.
- Simplify the yt-dlp window to one URL field, a checkbox result list,
  Video/Audio Only options and a destination footer.

### Fixed

- Choppy, half-length audio when extracting, converting or editing videos with
  HE-AAC audio, such as TikTok downloads; decoding now uses the real output rate.
- Swift exclusive-access crashes while changing video trim boundaries.
- Silent loss of unsupported audio tags during replacement; refuse replacement
  or disclose the loss when retaining the original with New File.
- Incomplete downloads caused by silently skipped media fragments.
- A verified empty H.264 tail found in a TikTok download; preserve every valid
  packet and timestamp, and continue rejecting other corruption.
- Duplicate CSV headers losing fields during JSON/XML conversion, and missing
  UTF-8 BOM in JSON-to-CSV output.

## [2.2.0] - 2026-11-05

### Added

- A top-level Finder yt-dlp action for folder backgrounds and single folders,
  with multiple URLs, explicit playlist selection, output formats, source
  resolutions and optional authored or automatic subtitle sidecars.
- Two concurrent media downloads, cancellation, failure-only retry, numbered
  collision-safe output names, Show in Finder and Undo.
- Bundled isolated download tools with pinned versions, third-party notices,
  corresponding sources and reproducible build instructions.

### Changed

- Show Activity after two seconds of ongoing work without taking Finder focus;
  enable this once on upgrade and preserve later preferences.
- Separate completed-file counts from measured stage progress; show unknown
  totals and compression searches without fabricated percentages.
- Open the localized official download page from update menus and notifications,
  including previously saved update information.


## [2.1.0] - 2026-11-02

### Support

- VoiceOver is outside the supported interaction modes from this release onward.

### Added

- Activity comparisons for original and processed still images, with synchronized
  zoom and position, actual-pixel inspection, dimensions and file sizes.
- Retry failed image, video and audio compression/conversion or PDF compression
  using the original settings, with an editable target size.
- Processing stages, elapsed time and individual file results in Activity.

### Fixed

- Keep Activity hidden by default; open progress and results from the menu bar
  when needed, or enable automatic display in Settings.
- Avoid redundant PNG encoding, repeated palette searches and oversized lossless
  optimization workspaces; propagate cancellation through pixel processing.
- Reuse lossless PNG filter work, remove full-frame RGB copies and release
  palette workspaces promptly.
- Balance PNG target compression with measured resizing and checked 256-color
  candidates. Use full-color resizing when palette reduction loses too much
  fidelity. Keep the full-resolution search when downscaling is disabled and
  reject candidates that fail its quality checks.
- Declare standard sRGB explicitly in balanced palette PNG output while
  preserving custom color profiles.
- Continue palette generation when one color region cannot split further,
  avoiding premature color loss and severe tinting in translucent images.
- Stop unsuccessful PNG target searches without repeating every candidate just
  to calculate a minimum-size estimate; keep the failure explicit and retryable.
- Separate image target-size downscaling settings from video settings while
  preserving existing preferences during migration.
- Keep GIF dithering settings from altering PNG compression output.
- Speed up PNG quality presets without changing their decoded pixels.
- Sign and verify the DMG container before generating its download checksum.
- Keep videos already within a custom byte limit unchanged instead of
  re-encoding them into larger files; reject larger quality-compression outputs.
- Copy compatible video and audio streams independently during conversion,
  while retaining required PCM timing correction for AVI.
- Preserve older recipe execution histories when decoding new image settings.
- Use consistent editor toolbar controls and improve narrow organization and
  recipe layouts; double-click the intended recipe row. Keep editable menu values
  and expanded rename options within their available space.
- Keep Activity reachable after fast jobs finish or its window closes.
- Restore Command-Q from application windows through the normal shutdown path.
- Keep folder-analysis chart labels separate and show an explicit empty state
  when AI Rename has no files.
- Report encoded ICO/ICNS dimensions and accepted GIF palette changes accurately;
  allow static GIF result comparisons.
- Distinguish optional lossless PNG optimization notices from compression
  outcomes and report palette or resolution reductions.

### Safety

- Recheck retry inputs and comparison files against their recorded identities;
  read replacement originals from the recorded Trash location without restoring
  or modifying them.
- Keep comparison and retry information in the current Activity session, with
  the existing persistent history and Finder request formats unchanged.

## [2.0.0] - 2026-11-01

### Added

- Content-based folder organization with editable policy previews, explicit
  per-folder automation, stable-write delays and local Apple Intelligence.
- Recent organization results with old-name search, saved category corrections,
  batch Undo and durable move recovery after interruption.
- Batch photo editing with shared adjustments, independent overrides,
  per-photo automatic correction and bounded preview caching.
- Multi-source video timelines with segment editing, continuous audio and
  letterboxed, source-preserving MP4 export.
- PDF page reordering and deletion with session Undo/Redo and verified
  annotations, form values and internal navigation.
- Saved finishing recipes for mixed images, videos and PDFs, multiple variants,
  folder or ZIP delivery, optional total size limits and one package Undo.

### Safety

- Publish recipe packages only after every required output passes verification;
  keep original inputs and reject changes during processing.
- Journal organization move intent before mutation, avoid overwrites, and remove
  only unchanged, empty folders owned by an undone organization batch.
- Preserve existing history, settings and single-source timeline decoding.
- Disclose SDR/opaque joined-video output before saving; keep all sources.

## [1.4.0] - 2026-10-30

### Added

- Single-source video segments with split, gap-closing deletion, duplication,
  drag reordering, visible controls and a timeline context menu.
- Command-B and Backspace editing with text-field focus protection and session
  Undo/Redo; per-segment speed, volume, color and styles, with global geometry
  and resolution.
- Immediate in-place HatchZip extraction for supported local ZIP, 7z, TAR,
  tar.gz/tgz and recognized numeric split volumes, using a pinned Rust helper
  with hatchzip-core 0.1.8 and UnRAR disabled.
- Durable HatchZip pause/resume and recovery after relaunch, independent of
  ordinary history retention.

### Changed

- Order image and video menus as Edit, Convert, Compress, Resolution.
- Retain the video player surface and prepare frames before presentation;
  coalesce preview work and refine interactive photo previews.
- Remove editor histograms, keyframe-mode controls and slider tick rows.
- Keep ordinary Finder extraction for RAR only; ZIP browsing and selective
  export remain available and retain the archive.
- Require Rust 1.93 or later, including Cargo, when building from source.

### Safety

- HatchZip is an explicit exception to original retention and destructive-action
  confirmation: it starts without confirmation, consumes archive bytes as
  verified output becomes durable, keeps no original archive and has no Undo.
- Verify archives, split volumes, paths, expansion limits and free space before
  destructive extraction; refuse unsupported cloud/network locations,
  hard-linked inputs and untrusted recovery records before mutation.
- Preserve incomplete HatchZip sessions and outputs when paused or when ordinary
  history is cleared; never overwrite existing outputs.

## [1.3.0] - 2026-10-30

### Added

- Shared photo/video editor with a resizable landscape workspace and Liquid Glass Save.
- Direct timeline range handles, range movement, scrubbing, frame stepping and zoom.
- Shared crop, aspect presets, rotation, flips, straightening, color adjustments and styles.
- Photo automatic correction, black point, sharpness, noise reduction, vignette and zoom.
- Video volume/mute, original comparison, session Undo/Redo and luminance/RGB histograms.
- Cancellable temporary playback for supported non-native video formats.

### Safety

- HDR color editing always previews SDR and saves a new SDR file, preserving the original.
- Recheck source identity before saving and exporting; reject animated/multipage photo editing.
- Preserve existing staging, verification, collision handling, Trash and history Undo.

## [1.2.0] - 2026-10-28

### Added

- Image long-edge 720/480/360 px and video 360p presets under Resolution & Size.
- Pitch-preserving video speed presets and arbitrary custom values from 0.5–4×.
- Edit Video combines trimming, speed and resolution, with output previews.
- Folder Access settings and Welcome folder registration using native pickers.
- A Finder Services chooser for locations that suppress Finder Sync menus.

### Fixed

- Register standard and bookmark-resolved user folders explicitly with Finder.
- Preserve video/audio timing across speed changes and silent selections.
- Select supported AAC bitrates for low-sample-rate speed outputs.
- Clarify requested duration when trimming at keyframes.

## [1.1.0] - 2026-10-26

### Added

- Static-PNG SVG tracing with original/output comparison, 1–8 colors, and
  three detail levels. Save keeps the original and writes the displayed paths.
- ZIP browsing with hierarchical search, selected-file previews, and selective
  export with collision-safe names and Undo. Closing releases temporary content;
  startup cleanup recovers content left after a crash.
- Source identity checks for preview exports, bounded ZIP listing and preview
  sizes, and validation of paths, member types, CRCs, and expansion limits.

### Fixed

- Reject special-file inputs before reading job metadata, and preserve persisted
  Undo timestamp compatibility when taking file stamps without opening inputs.

## [1.0.0] - 2026-10-23

### Added

- A Finder context menu for images, video, audio, PDFs, text, folders,
  archives, and JAR files, with English and Japanese localization.
- Image resizing, compression, rotation, flipping, border trimming, format
  conversion, OCR, metadata removal, background editing, and icon export.
- Video resizing, trimming, compression, rotation, frame-rate changes, audio
  removal, container conversion, animation export, thumbnails, and backgrounds.
- Audio conversion, compression, loudness normalization, and trimming.
- Folder renaming, trees, disk usage reports, duplicate and empty-folder removal,
  and ZIP, 7z, TAR, or tar.gz creation.
- Archive extraction with path, link, and size checks; JAR decompilation with
  bundled CFR and a separately installed Java runtime.
- PDF merge, split, page extraction, rotation, compression, and image or text export.
- Text encoding and line-ending changes, structured conversions, and JSON formatting.
- Optional Apple Intelligence naming and reviewed plans for supported operations.
- Editable platform presets, menu bar progress and history, onboarding, settings,
  GitHub update checks, and Undo for supported file operations.
- HDR-to-SDR conversion for supported images and video through Convert > SDR.
- Audio transcription to SRT, WebVTT, plain text, or translated SRT.
- DOCX, ODT, RTF, and RTFD export to PDF or TXT.
- Offline HTML export to PDF or rendered TXT.
- Markdown export to HTML or PDF, with raw HTML and unsafe links omitted.
- JSON conversion to and from YAML, TOML, and XML or binary property lists.
- Plain-text SRT and WebVTT conversion with timing preserved.
- PSD composite export to PNG, JPEG, or TIFF, retaining the layered original.
- Multipage TIFF export from PDF at the saved image resolution.
- M4A ALAC audio extraction, CAF PCM and ALAC conversion, and AIFF-C input.
- TGA conversion on systems where ImageIO supports reading and writing it.
- An Activity window with batch and folder-scan progress, Stop, results, and Undo.
- Individual Finder menu visibility and editable resize, compression, and
  extra-angle values, with validation and reset.
- Duplicate matching filters and policies to keep the oldest or newest copy
  automatically, while retaining byte-by-byte verification.
- Folder, filename, and extension exclusions for all folder scans or individual
  features.
- Combined multi-folder Analyze reports with CSV, JSON, HTML, TXT, and Markdown
  exports.
- OCR file encoding choices and a custom Shift_JIS replacement character.
- JSON sort options for comparison, direction, pinned keys, and primitive arrays.
- Embedded-PNG SVG output and PDF page images saved next to the source.
- SHA-1 and SHA-512 checksum menu choices, hidden by default on new installs.
- Reset All Settings in Advanced, retaining history and edited platform presets.
- A menu bar attention badge after a batch with failures, or when the Finder
  extension is off after setup. Opening the menu clears it.

### Changed

- New app icon, menu bar icon, and Finder menu icon: a page with a context
  menu. The menu bar icon tells VoiceOver whether MacEase is working.
- Conversions and edits save new files by default, with collision-safe names
  and Undo. Replace original remains an option in General settings.
- Finder menus run presets and formats directly, group Flip under Rotate and
  animations under Convert, and offer Custom Size only for Resize and Compress.
- Settings uses a sidebar, with Finder Menu controls and persistent operation
  defaults replacing option panels.
- One Welcome window handles setup. Reopening the app shows Welcome until setup
  is done, then Settings.
- Completion banners avoid duplicating results retained in Activity. Skipped
  files are counted separately from failures.
- Empty-folder removal uses a confirmation alert after scanning in Activity.
- Large text encoding and line-ending conversions use less memory.
- JSON formatting streams input and output; key sorting uses temporary disk
  storage instead of retaining the entire document in memory.
- Case-insensitive JSON key comparison and pin matching fold keys in chunks.
- Large Images to PDF jobs write pages incrementally instead of retaining them all.
- Large removal batches write less undo history while keeping committed removals
  recoverable after an application crash.

### Fixed

- Report successful conversions as complete in Activity and group repeated
  notices without counting them as failures.
- Show Finder actions on separately mounted and network volumes, including
  volumes attached after the extension starts.

- When ImageIO cannot preserve a valid HDR gain map during an image edit,
  new-file output uses SDR with a warning. Replace still refuses HDR loss.
- Keep natural JSON ordering deterministic for long combining-character
  prefixes affected by Foundation's string-representation-dependent results.
- Bound natural JSON key comparison memory with disk-backed collation while
  preserving existing Unicode and numeric ordering.
- Expose settings switch titles and onboarding status labels to VoiceOver.
- Keep Finder catalog versions stable across launches with unchanged metadata
  settings, avoiding rejected requests caused by unordered set encoding.
- Preserve U+FEFF within UTF-8 text at chunk boundaries during encoding,
  line-ending and JSON formatting operations.
- Split SVG luminance calculation into typed components so Xcode 26 can build it.
- Use macOS's system Bash for native dependency builds, avoiding a heredoc
  hang with a PATH-selected Bash installation.
- Regenerate bundled third-party notices before packaging a DMG, so cached native
  builds cannot omit the Swift package and toml++ licenses.
- MKV and WebM files from ffmpeg or mkvmerge no longer report lost metadata
  or refuse replacement because of encoder and statistics tags.
- FLV files written by ffmpeg, OBS and similar tools convert and edit again;
  their technical and encoder metadata no longer blocks processing.
- Refuse INI global keys matching section names before JSON or XML output,
  reporting the offending path instead of merging conflicting values.
- Preserve disabled Matroska/WebM tracks in supported video outputs and
  disclose or refuse enabled-state loss in other destinations.
- Preserve Opus output gain when extracting or re-encoding Matroska and WebM
  audio.
- Preserve 16-bit SDR precision in PNG and TIFF image edits, including
  arbitrary-angle rotation and transparent padding.
- Preserve native video clean aperture and pixel aspect ratio when copying
  MOV, MP4 and M4V inputs to Matroska, with the existing loss warning or
  replacement refusal for unsupported geometry.
- Preserve Matroska display aspect and pixel cropping when supported; warn
  about unsupported output geometry and refuse replacement before staging.
- Stop further file changes when undo history cannot be saved, and resume after
  pending history is successfully synchronized.
- Refuse duplicate JSON row keys in CSV and conflicting XML text or attribute
  names, reporting the offending path.
- Detect Matroska track names and BCP47 languages before metadata loss checks;
  warn for new files and always-derived exports, and refuse replacement.
- Preserve ALAC/FLAC source precision in lossless audio extraction, refusing
  unknown or unrepresentable precision before staging.
- Preserve PCM extraction delays, gaps, and trim edits without reducing
  integer precision.
- Refuse audio replacement when tags cannot be preserved or read; new-file
  conversion reports a warning and retains the original.
- Refuse lossless audio transforms above 24-bit integer or 32-bit float
  source precision before writing instead of silently losing precision
  through Float32 decoding.
- Video compression preserves transparency in supported MOV and WebM outputs.
- Arbitrary-angle video rotation preserves source transparency in alpha outputs.
- Matroska and WebM title or tag loss warns for new files and refuses replacement.
- HDR thumbnails tone-map to SDR and report the conversion while keeping originals.
- Explicit video SDR conversion checks metadata loss before staging and after writing.
- Ordinary video edits preserve supported PQ/HLG HDR with HEVC Main10.
  SDR-only outputs tone-map with a warning; replacement refuses HDR loss.
- Dolby Vision 8.4 (iPhone HDR) new-file edits keep the HLG base layer or
  tone-map for SDR targets, with warnings; replacement refuses.
- Native video remuxes and edits preserve metadata and track attributes;
  unsupported property loss warns for new files and refuses replacement.
- Preserve Finder dates, tags, and comments on source-backed exports.
- Apply the confirmed batch rename preview with snapshotted exclusions and
  targets; refuse names occupied after confirmation.
- Keep single-folder archives inside the archive-stem extraction folder.
- Image conversions disclose lost EXIF, XMP and IPTC metadata in new-file mode
  and refuse replacement before writing when the target cannot preserve it.
- Ordinary multipage TIFF edits preserve each page's own metadata.
- Generated TOML above 1 MiB remains valid within the 8 MiB output limit.
- Pipe-delimited CSV conversion detects columns while preserving quoted fields.
- Automatic duplicate removal saves each Trash move before continuing, preserving
  Undo after interruption and stopping when history cannot be saved.
- Native audio copying preserves source priming, end padding, and presentation
  timing during remuxing, video conversion, trimming, and audio extraction.
- Audio copying into containers without edit lists avoids negative start
  timestamps and preserves A/V timing within one audio frame. Matroska and
  WebM retain Opus delay metadata.
- TIFF metadata stripping preserves each page's retained metadata and checks
  all pages for fields to remove.
- Property-list conversion rejects excessive shared-value expansion before
  generating JSON and includes the final newline in its output limit.
- Convert > SDR only offers supported video containers and rejects unsupported
  inputs before AVFoundation opens them.
- New image outputs warn when flattening transparency or tone-mapping HDR.
  Image edits and format conversions in Replace mode refuse unrequested losses.
- Image conversions reject frame or page loss and preserve representable finite
  animation loop counts.
- Output naming advances past occupied paths, including dangling symbolic links.
- YAML conversion rejects excessive alias expansion, and XML property lists
  reject duplicate dictionary keys before values can be lost.
- Repeated TOML conversions release their native allocations.
- Failed staging cleanup is retried, and normal quit waits briefly for cancelled
  jobs to clean up.
- HDR videos with edit lists, such as those encoded with x265, convert to SDR
  instead of being refused.
- Folder-scan progress no longer moves backward when callbacks arrive out of order.
- The menu bar's busy icon stays still when Reduce Motion is enabled.
