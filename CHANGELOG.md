# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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

### Changed

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
- Large Images to PDF jobs write pages incrementally instead of retaining them all.
- Large removal batches write less undo history while keeping committed removals
  recoverable after an application crash.

### Fixed

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

## [1.0.0] - 2026-10-21

First release.

### Added

- A MacEase submenu in Finder's context menu, built from the selected file
  kinds, with operations you can hide in Settings.
- Images: resize, compress to a target size, rotate by any angle, flip, trim
  borders, convert between PNG, JPEG, HEIC, WebP, AVIF, JPEG XL, GIF, TIFF, BMP,
  ICO, ICNS, SVG and PDF, OCR, strip metadata, remove or replace the
  background, and export app icon sets.
- Videos: resize, trim, compress to a target size, rotate, flip, change the
  frame rate, remove audio, convert between MP4, MOV, M4V, MKV, WebM, AVI and
  FLV, make GIF, animated WebP or APNG, extract audio, export thumbnails,
  generate and translate subtitles, and remove the background into transparent
  video or a green or blue screen.
- Audio: convert between MP3, M4A, AAC, WAV, AIFF, FLAC, OGG and Opus,
  compress, normalize loudness and trim.
- Folders: remove duplicates and empty folders, print a tree, batch rename,
  analyze disk usage, and compress to ZIP, 7z, TAR or tar.gz.
- Archives: extract ZIP, 7z, TAR, gz, bz2, xz and RAR, with path, link and
  size checks.
- PDFs: merge, split, extract pages, rotate, compress, and export pages as
  images or text.
- Text: change the encoding and line endings, convert between CSV, JSON, XML,
  HTML, Markdown and INI, and pretty-print or sort JSON.
- JAR files: decompile to source with the bundled CFR when a Java runtime is
  installed.
- Apple Intelligence: rename files by their content and describe a task in
  plain words, on Macs with Apple Intelligence turned on.
- Editable platform presets for Discord, X, Instagram, LINE, email and the web.
- Safe replacement: outputs are verified before they replace an original, the
  original goes to the Trash, and every batch can be undone from the
  notification or the menu bar.
- A menu bar app with job progress, recent batches, settings, onboarding and
  update checks.
- English and Japanese localization.
- An app icon, shown in Finder and the About tab.
