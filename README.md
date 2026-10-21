# MacEase

English | [日本語](README.ja.md)

MacEase converts, compresses, and edits selected files from Finder's right-click
menu. Conversions and edits save new files by default. Optional replacement
moves originals to the Trash and supports Undo.

Processing runs on your Mac. The app checks GitHub for updates. Some Apple
features require installed language assets or models.

## Features

- **Images:** resize, compress, rotate, flip, trim borders, edit backgrounds,
  remove metadata, recognize text, and export icons or an AppIcon set. Convert
  supported images to PNG, JPEG, HEIC, WebP, AVIF, JPEG XL, GIF, TIFF, BMP, ICO,
  ICNS, SVG, or PDF. TGA conversion appears when ImageIO supports reading and
  writing it. PSD exports use the stored composite and offer PNG, JPEG, or TIFF,
  keeping the layered original. Decodable camera RAW files also keep their
  originals. SVG output can trace paths or embed a PNG.
- **Videos:** resize, trim, compress, rotate, flip, change frame rate, remove
  audio, and convert supported streams between MP4, MOV, M4V, MKV, WebM, AVI,
  and FLV containers. Export GIF, animated WebP, APNG, thumbnails, audio,
  or video with a transparent, colored, or blurred background. Audio extraction
  includes M4A with AAC or ALAC.
- **HDR to SDR:** use **Convert > SDR** for supported HDR images and video.
  The host checks the content and skips SDR inputs. Image conversion supports
  single-image JPEG, HEIC, AVIF, JPEG XL, and PNG sources. Video conversion
  supports compatible MP4, MOV, and M4V sources, including supported Dolby
  Vision 8.4 base layers.
- **Audio:** convert MP3, M4A with AAC or ALAC, raw AAC, WAV, AIFF, FLAC,
  Ogg Vorbis, Opus, and CAF with PCM or ALAC. AIFF-C input depends on its codec.
  Compress, normalize loudness, or trim audio.
- **Subtitles:** transcribe audio or video to SRT, WebVTT, or plain text,
  or export translated SRT using Apple's on-device Speech and Translation
  frameworks.
- **PDFs:** merge, split, extract pages, rotate, compress, and export text.
  Export pages as PNG or JPEG in a folder or next to the PDF, or as one
  multipage TIFF. Scanned PDFs use OCR for text export.
- **Documents and text:** export rich documents, render HTML or Markdown,
  convert structured text, and convert existing subtitle files as listed below.
  Change text encoding to UTF-8, UTF-8 with BOM, UTF-16, or Shift_JIS, normalize
  line endings, and pretty-print, minify, or sort JSON. Sorting supports key
  comparison, direction, pinned keys, and optional sorting of primitive arrays.
- **Folders:** rename contents, remove verified duplicates or empty folders,
  copy or save a folder tree, and analyze disk usage. Duplicate removal asks
  which copy to keep by default. A saved policy can keep the oldest or newest
  by modification time and move the other copies to the Trash automatically.
  Filters cover size, empty files, names, and modification times. Copies are
  compared byte by byte, and at least one copy is retained.
- **Reports and exclusions:** Analyze combines selected folders into one report
  and exports CSV, JSON, HTML, plain text, or Markdown. Folder, filename, and
  extension exclusions apply to all folder scans or to individual features.
- **Archives and utilities:** create ZIP, 7z, TAR, or tar.gz archives from
  folders. Extract ZIP, 7z, TAR, gz, bz2, xz, or RAR. Decompile JAR files with
  bundled CFR and an installed Java runtime. Calculate SHA-256, MD5, SHA-1,
  or SHA-512 checksums.
- **Apple Intelligence:** preview and confirm content-based names for images
  and PDFs, or turn a request into a plan of supported image, video, or audio
  operations.
- **Presets:** edit bundled targets for Discord, X, Instagram, LINE, email,
  and the web. Their values are app defaults, not a guarantee of a service's
  current upload limits.

The document and text conversion menu offers these directions:

| Source | Outputs |
| --- | --- |
| DOCX, ODT, RTF, RTFD | PDF, TXT |
| HTML | Source TXT, rendered TXT, PDF |
| Markdown | Source TXT, HTML, PDF |
| CSV | TXT, JSON, XML, HTML, Markdown |
| JSON | TXT, CSV, XML, XML or binary plist, YAML, TOML |
| XML | TXT, JSON |
| INI, CFG, CONF | TXT, JSON, XML |
| YAML, TOML | TXT, JSON |
| XML or binary plist | JSON |
| SRT, WebVTT | Source TXT, the other subtitle format |
| Other recognized text files | TXT, except files already classified as TXT |

Document export uses basic rich-text reflow and can change Office layouts.
HTML rendering blocks scripts and external resources and exports one continuous
PDF page. Markdown omits raw HTML and unsafe links. Structured conversions can
lose comments and formatting and reject unsupported value mappings. JSON to CSV
requires an array of flat objects. Subtitle conversion accepts a plain-text
subset and rejects unsupported styling or metadata. These exports keep their
sources in either output mode.

Image conversions refuse to discard animation frames or TIFF pages. When a new
image file cannot retain transparency or HDR, supported paths flatten against
the chosen background or tone-map to SDR and report a warning. Image edits and
format conversions in Replace mode refuse unrequested transparency or HDR loss.
Explicit **Convert > SDR** follows the selected output mode. Video edits in
either output mode refuse multiple video or audio tracks and streams they
cannot preserve. Explicit exports keep the source and report omitted streams.
Container support does not imply support for every codec inside it.

SDR-to-HDR conversion, WMA, AV1 video encoding, and RAR creation are not
implemented. Media operations act on selected files, without scanning folders
for media.

[docs/SPEC.md](docs/SPEC.md) describes the target product, including acceptance
criteria that are not all verified on every supported macOS version.

## Requirements

- An Apple Silicon Mac running macOS 26 or later.
- The MacEase Finder extension enabled for the context menu.
- Apple Intelligence enabled and its on-device model available for AI features.
  Other operations do not require Apple Intelligence.
- Supported, installed Speech language assets for transcription and installed
  Translation models for translated subtitles. MacEase reports missing assets.
- A Java runtime discoverable by macOS for JAR decompilation.

## Install

1. Download `MacEase-<version>.dmg` from
   [Releases](https://github.com/TKY-27/MacEase/releases/latest) and check its
   SHA-256 against the checksum on the release page.
2. Open the DMG and drag **MacEase** to **Applications**.
3. Open MacEase. macOS blocks it the first time because it is not notarized.
4. Open **System Settings > Privacy & Security**, scroll down, and click
   **Open Anyway** next to MacEase, then confirm.
   Alternatively, run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/MacEase.app
   ```
5. In the Welcome window, enable the Finder extension. Allow notifications
   if you want completion banners, then click **Done**.

Release builds use a self-signed certificate and are not notarized by Apple.
You can also build from source.

## Usage

1. Select files or folders in Finder, right-click, and choose **MacEase**.
   A selection of one file kind shows its operations directly. Mixed selections
   group operations by kind and count.
2. Choose a preset or format to run it immediately. **Flip** is under
   **Rotate**, animation exports are under video **Convert**, and HDR conversion
   is **Convert > SDR**. **Custom Size…** appears only under **Resize** and
   **Compress**. Other windows collect required input, confirm removals,
   or show results. PDF merge and Make PDF from multiple images open a page-order
   window.
3. Batches still running after 0.8 seconds appear in **Activity**, without
   taking focus from Finder. Use **Stop** to cancel a batch. Closing the window
   leaves jobs running. Folder scans also show progress there.
4. With default settings, clean successes close automatically. Warnings,
   skipped files, and failures remain when Activity is visible. A completion
   banner appears when the result is not already retained there, if notifications
   are enabled. Use **Show in Finder** or **Undo** where available. Recent
   batches also appear in the menu bar.

In **Settings > General > When converting or editing**, choose **Save as new
file** or **Replace original**. New files appear next to their sources, with
numbered names when needed to avoid overwrites. Replacement verifies the output
before moving the original to the Trash. Exports and extracts always retain
sources. Undo moves created outputs to the Trash or restores replaced originals.
It can skip changed files or originals no longer available in the Trash.
Permanent deletion requires confirmation and cannot be undone.

<img src="docs/images/compress-en.png" width="420" alt="The Custom Size panel for Compress with a 10 MB target">

Open **Settings** from the menu bar icon. Its sidebar has **Finder Menu** and
pages for each file kind. **Finder Menu** controls visibility of individual
presets and formats, editable resize and compression values, an extra rotation
angle, and platform presets. Some formats and utilities are hidden by default.
Other pages hold quality, background, animation, audio, subtitle, OCR, PDF,
folder, and text defaults. **Advanced > Reset All Settings…** keeps history and
edited platform presets. Opening MacEase again shows Welcome until setup is
done, then Settings.

<img src="docs/images/settings-en.png" width="640" alt="MacEase Settings, General page">

## Build from source

Requirements: Apple Silicon Mac, macOS 26 or later, Xcode 26 or later, and
Homebrew. Xcode 27 is required to build macOS 27-specific features.

```sh
git clone https://github.com/TKY-27/MacEase.git
cd MacEase
make bootstrap
make build
make test
```

Before first launch, copy `build/DerivedData/Build/Products/Debug/MacEase Dev.app`
to `~/Applications` or `/Applications`. Welcome cannot finish outside those
folders. Enable the Finder extension from Welcome or
**System Settings > General > Login Items & Extensions**.

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Architecture

A sandboxed Finder Sync extension builds the context menu from a catalog written
by the menu bar app. It forwards the selected operation and file paths through
a token-checked URL scheme. The host runs jobs and presents input panels,
Activity, and Settings. `Packages/MacEaseKit` contains `MenuCatalog`, `Engine`,
and `Formats`.

Apple frameworks provide native document, image, media, OCR, speech, and
translation support. Bundled Swift package dependencies include **swift-cmark**
for Markdown and **Yams**, including libyaml, for YAML. Vendored **toml++** runs
behind an owned C bridge for TOML. Other format support uses permissively
licensed libraries, including libwebp, libavif, libjxl, libvpx, libopus, and
libarchive, plus independent implementations such as the MP3 and GIF encoders,
Matroska and WebM containers, and SVG tracing.

Details: [docs/SPEC.md](docs/SPEC.md) and [docs/adr/](docs/adr/).

## Contributing

Issues and pull requests are welcome. Read
[CONTRIBUTING.md](CONTRIBUTING.md) and the
[Code of Conduct](CODE_OF_CONDUCT.md). Report security issues privately as
described in [SECURITY.md](SECURITY.md).

## Acknowledgments

[Flect](https://github.com/Konayukiw/Flect), a Windows Explorer toolkit, is the
reference for menu interactions and features. MacEase independently implements
that design for macOS without reusing Flect code or assets.

## License

[MIT](LICENSE). Bundled dependencies retain their own licenses, including
swift-cmark's BSD and MIT notices, Yams and libyaml's MIT licenses, and
toml++'s MIT license. Their license texts are in `Vendor/licenses/` and are
included with the native library notices in the app's `THIRD_PARTY_NOTICES.txt`.
Open **Settings > About > Third-Party Notices** to read them.
