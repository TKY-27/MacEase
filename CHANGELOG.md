# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- An Activity window that appears when a batch runs longer than a moment,
  without taking focus from Finder. It shows the current file, done/total and
  a Stop button, closes after clean successes, and keeps problems listed with
  Show in Finder and Undo. The menu bar adds Show Progress while jobs run.
- A Finder Menu page in Settings that shows or hides individual menu items,
  such as single sizes or formats, alongside the extra rotation angle and the
  platform preset editor.
- Reset All Settings in Settings > Advanced.
- Remove Duplicates can keep the oldest or newest copy without asking, and
  can skip small or empty files or require matching names or modification
  times. Copies are still compared byte by byte.
- Exclusion rules for folders, files and extensions, for all folder scans or
  for one feature such as Folder Tree or Analyze.
- Analyze combines several selected folders in one report and exports CSV,
  JSON, HTML, plain text or Markdown.
- Editable menu values for resize percentages, long edges, video heights,
  compress sizes and the extra rotation angle, with inline validation and
  reset.
- Settings for the OCR text file encoding, a custom Shift_JIS replacement
  character, JSON key comparison, order, keys first and list sorting, SVG
  conversion by tracing or embedding a PNG, and PDF page images in a new
  folder or next to the PDF.

### Changed

- Settings uses a sidebar with pages for each kind of file. The choice between
  saving a new file and replacing the original is a described option on the
  General page, together with the progress window options.
- One Welcome window replaces the multi-page onboarding. Opening MacEase again
  shows Welcome until setup is done, then Settings.
- Custom Size for Resize asks only for width and height; Custom Size for
  Compress asks only for a size in megabytes. Their other choices come from
  Settings. The menu bar's busy icon stays still when Reduce Motion is on.
- Scans for duplicates, empty folders and Analyze show their progress in the
  Activity window. Remove Empty Folders asks for confirmation in an alert
  instead of a checklist window.
- The Activity window reports skipped files separately, for example
  "Finished — 3 skipped.", instead of counting them as problems.

- Updated the target v1 specification and ADR policy for Flect-style menu-first
  interaction, new-file output by default, HDR/SDR scope, and independent Swift
  implementation with source study permitted. Implementation follows separately.

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
