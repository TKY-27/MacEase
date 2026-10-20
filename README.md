# MacEase

**Right-click any file in Finder to convert, compress, resize and more.**

English | [日本語](README.ja.md)

MacEase adds one menu to Finder's context menu. Select files, right-click, pick
what you want, and the files are transformed in place. No app window to open, no
website to upload to, no video editor just to shrink a clip for Discord.

> MacEase is under active development. Sections marked *(to be completed)* are
> filled in as features land.

## Why

- iPhone photos arrive as HEIC and some sites refuse them.
- A screen recording is too large for Discord, X or email.
- A clip should be a GIF, an image needs a transparent or green background, a
  folder is full of duplicates.

macOS covers a few of these with Quick Actions, but formats, size targets and
batch work are limited. MacEase puts all of it one right-click away, runs
entirely on your Mac, and is free and open source under the MIT License.

## Features

- **Images:** resize, compress to a target size, rotate any angle, flip, trim
  borders, convert between PNG, JPEG, HEIC, WebP, AVIF, JPEG XL, GIF, TIFF, BMP,
  ICO, ICNS, SVG and PDF, OCR, strip metadata, remove the background or replace
  it with green, blue, any color or blur, export app icon sets.
- **Videos:** resize, trim, compress to a target size, rotate, flip, change frame
  rate, remove audio, convert between MP4, MOV, M4V, MKV, WebM, AVI and FLV,
  make GIF, animated WebP or APNG, extract audio, export thumbnails, generate and
  translate subtitles, remove the background into transparent video or a green or
  blue screen.
- **Audio:** convert between MP3, M4A, AAC, WAV, AIFF, FLAC, OGG and Opus,
  compress, normalize loudness, trim.
- **Folders:** remove duplicates and empty folders, print a tree, batch rename,
  analyze disk usage, compress to ZIP, 7z, TAR or tar.gz.
- **Archives:** extract ZIP, 7z, TAR, gz, bz2, xz and RAR.
- **PDFs:** merge, split, extract pages, rotate, compress, export pages as images
  or text.
- **Text:** change encoding (UTF-8, UTF-16, Shift_JIS) and line endings, convert
  between CSV, JSON, XML, HTML, Markdown and INI, pretty-print and sort JSON.
- **Apple Intelligence:** describe what you want in plain words, or rename files
  by their content, on supported Macs.
- **Platform presets:** one click to fit Discord, X, Instagram, LINE, email or
  the web. Presets are editable.

Your originals are safe: a file is replaced only after the new version is fully
written and checked, the original goes to the Trash, and every batch can be
undone from the notification or the menu bar.

The full behavior of every operation is specified in [docs/SPEC.md](docs/SPEC.md).

## Requirements

- A Mac with Apple Silicon
- macOS 26 or later
- Apple Intelligence features need a Mac with Apple Intelligence turned on
- JAR decompiling needs a Java runtime

## Install

1. Download `MacEase-<version>.dmg` from
   [Releases](https://github.com/TKY-27/MacEase/releases/latest) and check its
   SHA-256 against the checksum on the release page.
2. Open the DMG and drag **MacEase** to **Applications**.
3. Open MacEase. macOS blocks it the first time because it is not notarized.
4. Open **System Settings > Privacy & Security**, scroll down and click
   **Open Anyway** next to MacEase, then confirm.
   Alternatively, run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/MacEase.app
   ```
5. Follow the onboarding screen to turn on the Finder extension and
   notifications.

MacEase is signed with its own certificate but not notarized by Apple, because
it is a personal open-source project without a paid developer account. You can
build it yourself from source instead (see below).

## Usage

Select one or more files in Finder, right-click, and choose **MacEase**.

*(to be completed: screenshots and a short walkthrough)*

## Build from source

Requirements: Apple Silicon Mac, macOS 26 or later, Xcode 26 or later (Xcode 27
for macOS 27 features), Homebrew.

```sh
git clone https://github.com/TKY-27/MacEase.git
cd MacEase
make bootstrap
make build
make test
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Architecture

MacEase has two parts: a sandboxed Finder Sync extension that draws the menu,
and a menu bar app that does the work. The extension passes your choice and
selection to the app through a private URL scheme. The core logic lives in the
`MacEaseKit` Swift package. Formats that Apple does not provide are handled by
permissively licensed libraries (libwebp, libavif, libjxl, libvpx, libopus,
libarchive and others) or by MacEase's own Swift implementations (MP3 encoder,
GIF encoder, Matroska/WebM, SVG tracing and more).

Details: [docs/SPEC.md](docs/SPEC.md) and [docs/adr/](docs/adr/).

## Contributing

Issues and pull requests are welcome. Please read
[CONTRIBUTING.md](CONTRIBUTING.md) and the
[Code of Conduct](CODE_OF_CONDUCT.md). Report security issues privately as
described in [SECURITY.md](SECURITY.md).

## Acknowledgments

MacEase was inspired by [Flect](https://github.com/Konayukiw/Flect), a
right-click toolkit for Windows Explorer. MacEase is an independent project
written from scratch for macOS.

## License

[MIT](LICENSE). Bundled third-party components are listed with their licenses in
`THIRD_PARTY_NOTICES.txt` inside the app (Settings > About).
