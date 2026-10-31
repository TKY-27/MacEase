<div align="center">

<img src="docs/images/app-icon.png" width="128" alt="MacEase app icon">

# MacEase

**English | [日本語](README.ja.md)**

**Right-click and done.**

Convert, compress, and edit files and folders straight from Finder's
right-click menu, without opening another app.

</div>

---

## Installation

1. Download `MacEase-<version>.dmg` from
   [Releases](https://github.com/TKY-27/MacEase/releases) and check its
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
You can also [build from source](#build-from-source).

After setup, select files or folders in Finder, right-click, and choose
**MacEase**. Open **Settings** from the MacEase menu bar icon. Opening MacEase
again shows Welcome until setup is done, then Settings.

**Settings > Folder Access** lists standard and added folders. Use **Add Folder…**
here or in Welcome, check access, and open a location in Finder. Registration
is separate from macOS permissions. Removing an entry does not revoke access.
If an iCloud folder suppresses the MacEase menu, use **Services > Process with
MacEase…** (Finder may show it directly in the context menu). If macOS leaves
an access request waiting, select the affected folder with **Add Folder…**,
restart MacEase, and retry. This does not require Full Disk Access.

---

## Features

**Conversions and edits keep originals by default. HatchZip extraction consumes its archive.**

By default, every conversion and edit saves a new file next to its source,
with a numbered name when needed to avoid overwrites. Exports and ordinary
extracts keep their sources. If you prefer, **Settings > General** can replace
originals instead: MacEase verifies the output before moving the original to
the Trash. Undo moves created outputs to the Trash or restores replaced
originals. It can skip files that changed since, or originals no longer in the
Trash. Other permanent deletion is off by default, requires confirmation, and
cannot be undone.

**Extract with HatchZip is the exception:** it starts without confirmation,
progressively releases source archive bytes as verified output becomes durable,
and does not retain the original archive or offer Undo.

Select as many files as you like. A selection of one file kind shows its
operations directly; mixed selections group operations by kind and count.
Choosing a preset or format runs it immediately. Items ending in **…** open a
window for input, review, or confirmation. Image and video menus start with
**Edit**, **Convert**, **Compress**, then **Resolution**.

### Images

| Operation | What it does |
| --- | --- |
| **Edit Photo…** | Edit one or several photos; apply adjustments to selected photos or all, then refine each separately |
| **Convert** | PNG, JPEG, HEIC, WebP, AVIF, JPEG XL, GIF, TIFF, BMP, TGA, ICO, ICNS, SVG, or PDF; **SDR** for supported HDR images |
| **Compress** | Platform presets, quality levels, or a **Custom Size…** target |
| **Resolution** | Scale by percentage or long edge, including 720, 480 and 360 px, or enter a **Custom Size…**; low-resolution presets never enlarge |
| **Trace to SVG…** | Compare a static PNG with editable SVG paths; choose 1–8 colors and three detail levels, then save a new file |
| **Rotate** | Right-angle turns and an extra editable angle; **Flip** horizontally or vertically |
| **Background** | Remove it, or replace it with a green, blue, or custom color, or a blur |
| **Remove Metadata** | Strip all metadata, location only, or selected fields |
| **Recognize Text** | Read text from the image, then copy it, save it as `.txt`, or show it |
| **Make PDF** | Combine selected images into one PDF, with a page-order window for several |
| **Make Icon** | Export a macOS `.icns`, a Windows `.ico`, or an iOS AppIcon set |
| **Trim Borders** | Crop away uniform borders |
| **Copy as Base64** | Copy the image as a `data:` URI (hidden by default) |

TGA conversion appears when ImageIO supports reading and writing it. PSD
exports use the stored composite and offer PNG, JPEG, or TIFF, keeping the
layered original. Decodable camera RAW files also keep their originals. SVG
output can trace paths or embed a PNG. The separate **Trace to SVG…** action opens a
comparison for one static PNG and always saves editable paths as a new SVG.
It works best for logos and flat shapes. Photos, editable text, and reconstructed
gradients are outside its scope. Review any metadata, transparency, or HDR warning
before saving.

The photo and video editors use a resizable landscape workspace, with the
preview on the left and controls on the right. Drag a crop edge or corner, or
enter selection percentages; choose free/original, 1:1, 4:3, 3:2, 4:5 or 16:9.
Use Compare Original, per-adjustment reset and session Undo/Redo. Photos add
black point, sharpness, noise reduction, vignette and automatic correction.
Styles are independent presets, not Apple's Photographic Styles.
For several photos, use the file list to switch sources. Apply adjustments to selected
photos or all photos, then change each independently. Auto Enhance analyzes every
photo separately. Each source retains its own preservation policy.
Photo adjustments use an interactive preview followed by a refined render.
The video player surface stays in place while frames are prepared. Histograms,
keyframe-mode controls and slider tick rows are absent.
HDR color edits display **SDR · Save as new file** and always keep the original.
Animations and multipage images cannot be opened in Edit Photo; RAW renders
are saved in a writable format while retaining the RAW source.

### Videos

| Operation | What it does |
| --- | --- |
| **Edit Video…** | Join several videos; split, delete, duplicate and reorder segments, with segment adjustments and global geometry |
| **Convert** | MP4, MOV, M4V, MKV, WebM, AVI, or FLV; GIF, animated WebP, or APNG; **SDR** for supported HDR video |
| **Compress** | Discord, X, Instagram Reels, LINE, and Email presets, fixed size targets, quality levels, or a **Custom Size…** |
| **Resolution** | Scale by percentage or to a 2160p/1080p/720p/480p/360p short edge; **Custom Size…** fits a box |
| **Playback Speed** | 0.5, 0.75, 1.25, 1.5, 2 and 4× presets, plus arbitrary **Custom Speed…** from 0.5–4×; preserve pitch, including batch processing |
| **Thumbnail** | Save the first, middle, or a chosen frame as an image |
| **Subtitles** | Transcribe to SRT, WebVTT, or plain text, or export translated SRT |
| **Rotate** | Right-angle turns and an extra editable angle; **Flip** horizontally or vertically |
| **Extract Audio** | Save the soundtrack as M4A (AAC or ALAC), MP3, AAC, WAV, AIFF, FLAC, Ogg Vorbis, or Opus |
| **Frame Rate** | Change the frame rate |
| **Remove Audio** | Drop the audio tracks |
| **Background** | Export with a transparent, colored, or blurred background |

Edit one or several source videos as an ordered sequence of segments. Use
**Add Videos…** to append sources. Split at the playhead
with **Command-B**, delete a selected segment with **Backspace** to close the gap,
duplicate it, or drag to reorder. Visible controls and the timeline context menu
provide these actions too. Each action or drag supports session Undo/Redo;
editing shortcuts leave focused text fields available for typing. Speed, volume
and color/style settings apply to the selected segment; crop, rotation and
resolution apply to the whole output. Joined videos always save a new MP4
(H.264, SDR, opaque). The first source sets the initial canvas and frame rate;
other sizes fit with black borders. Silent sources contribute silence. Review
the HDR, transparency and metadata disclosure before saving. Multiple tracks
and transitions are outside this editor's scope.

### Audio

| Operation | What it does |
| --- | --- |
| **Convert** | MP3, M4A (AAC or ALAC), raw AAC, WAV, AIFF, FLAC, Ogg Vorbis, Opus, or CAF (PCM or ALAC) |
| **Subtitles** | Transcribe to SRT, WebVTT, or plain text, or export translated SRT |
| **Compress** | Bitrate presets or a **Custom Size…** target |
| **Normalize Loudness** | Match a loudness target |
| **Trim…** | Keep only the part you mark |

Subtitles use Apple's on-device Speech and Translation frameworks.

### PDFs

| Operation | What it does |
| --- | --- |
| **Edit Pages…** | Reorder or delete pages in one PDF, with selection, preview and Undo/Redo |
| **Merge** | Combine two or more PDFs in the order you choose |
| **Export as Images** | PNG or JPEG pages in a folder or next to the PDF, or one multipage TIFF |
| **Export as Text** | Save the text, using OCR for scanned PDFs |
| **Compress** | Make the PDF smaller |
| **Rotate** | Turn every page |
| **Extract Pages…** | Save the pages you pick as a new PDF |
| **Split into Pages** | Save one PDF per page |

PDF page editing follows the saved output mode. It verifies surviving annotations,
form values, outlines and internal links before publishing. Destinations on deleted
pages are removed; encrypted or permission-restricted documents may refuse editing.

### Documents and text

| Operation | What it does |
| --- | --- |
| **Convert** | Export rich documents, render HTML or Markdown, and convert structured text and subtitle files (see [Conversion formats](#conversion-formats)) |
| **Encoding** | Change to UTF-8, UTF-8 with BOM, UTF-16, or Shift_JIS |
| **Line Endings** | Normalize to LF or CRLF |
| **Pretty Print / Minify / Sort Keys** | Format JSON. Sorting supports key comparison, direction, pinned keys, and optional sorting of primitive arrays |

### Folders

<img src="docs/images/folder-en.png" width="480" alt="Finder context menu on a folder with MacEase open, showing Compress, Rename, Folder Tree, Analyze, Remove Duplicates, Remove Empty Folders, and Rename Contents with Apple Intelligence">

| Operation | What it does |
| --- | --- |
| **Organize…** | Review content-based categories, move loose files, and optionally enable automatic organization |
| **Compress** | Pack the folder into ZIP, 7z, TAR, or tar.gz |
| **Rename…** | Rename the contents with a live preview |
| **Folder Tree** | Copy the folder structure or save it as a file |
| **Analyze…** | Report disk usage across the selected folders and export it as CSV, JSON, HTML, plain text, or Markdown |
| **Remove Duplicates…** | Find verified duplicates and move the extra copies to the Trash |
| **Remove Empty Folders…** | Find empty folders and move them to the Trash after confirmation |

Duplicate removal asks which copy to keep by default. A saved policy can keep
the oldest or newest by modification time and move the other copies to the
Trash automatically. Filters cover size, empty files, names, and modification
times. Copies are compared byte by byte, and at least one copy is retained.
Folder, filename, and extension exclusions apply to all folder scans or to
individual features.

### Automatic organization

Start from Finder or **Settings > Organization**. Review the category folders,
instructions and proposed changes before approving a policy. Existing folders
stay in place; files move only within the selected root and volume. Meaningful
filenames stay unchanged; camera, scan and other generated names may be renamed.
Apple Intelligence runs locally. Unreadable, uncertain or unavailable classification
stays in place with a reason. No content is sent to an external AI service.

Automation is an explicit per-folder choice, separate from Folder Access. It waits
two minutes by default and checks that writing has stopped. Pause each folder
individually. **Recent Organization** shows old/new paths, old-name search, category
correction and batch Undo. Saved corrections guide later classification. Undo
preserves changed or conflicting files and removes only empty folders created by
that batch. Restored files are not immediately organized again.

### Finishing recipes

Select images, videos or PDFs and choose **Finish With Recipe**. The bundled
**Web Publishing** and **Submission** recipes can be edited, duplicated or deleted
in **Settings > Finishing Recipes**. Set format, dimensions, quality, filename
suffixes and multiple outputs for each supported kind. Video thumbnails and PDF
page images or text can be included. Unsupported inputs are reported before a run.

A run freezes its settings and generates every variant from its original. It
publishes one named folder or ZIP only after every required output is verified.
Originals stay in place, and one Undo removes the completed package. Select an
output folder when inputs come from several folders. Optional total limits count
all output file bytes for folders and the actual completed ZIP size. Retries are
limited; an unattainable limit fails without publishing an incomplete package.

### Archives and other files

| Operation | What it does |
| --- | --- |
| **Extract with HatchZip** | Extract supported local ZIP, 7z, TAR, tar.gz/tgz and recognized numeric split volumes in place, consuming the archive without confirmation or Undo |
| **Extract** | Unpack RAR into a new folder, retaining the archive |
| **Browse Contents…** | Search a ZIP hierarchy, preview selected files, and save selected files or folders without unpacking the whole archive |
| **Decompile** | Turn a JAR into Java source with bundled CFR and an installed Java runtime |
| **Checksum** | Calculate SHA-256, MD5, SHA-1, or SHA-512 for any file |

**HatchZip does not keep an original archive.** Keep a separate backup yourself
if you need one. Supported split names are `.zip.NNN`, `.7z.NNN` and
`.tar.gz.NNN`; a bare numeric extension is not enough. Preflight checks the
complete archive, volumes, paths, expansion limits and free space before
mutation. Unsupported cloud/File Provider and network locations, hard-linked
inputs and untrusted recovery records fail before destructive work. Existing
outputs are never overwritten. There is no fallback to ordinary extraction.

Pause preserves extracted files and recovery state; use **Resume** in Activity,
including after relaunch. Clearing ordinary history does not remove incomplete
HatchZip recovery sessions. Completed HatchZip jobs have no Undo. Source and
output share a volume; filesystem snapshots and hole-punching support can limit
space reclaimed. Ordinary extraction is RAR-only; macOS-supported gzip, bzip2
and xz files have no extraction action here. ZIP browsing remains separate and
keeps the archive.

ZIP browsing supports up to 100,000 entries, 32 MiB of name and extra metadata,
and 256 path components. A preview can expand up to 256 MiB. Images, PDFs, audio,
video, and read-only text appear in the window; HTML and scripts are never run.
Closing removes temporary previews. Files you explicitly save remain and support Undo.

### Apple Intelligence

| Operation | What it does |
| --- | --- |
| **Rename with Apple Intelligence…** | Preview and confirm content-based names for images and PDFs |
| **Rename Contents with Apple Intelligence…** | The same for the images and PDFs directly inside a folder |
| **Ask Apple Intelligence…** | Turn a request into a plan of supported image, video, or audio operations, review it, then run it |

### Presets

Compress offers bundled targets for Discord, X, Instagram, LINE, email, and the
web. You can edit them in **Settings > Finder Menu**. Their values are app
defaults, not a guarantee of a service's current upload limits.

### Panels, progress, and Undo

**Custom Size…** appears only under **Resolution** and **Compress**.
**Flip** is under **Rotate**, animation exports are under video **Convert**, and HDR
conversion is **Convert > SDR**. Other windows collect required input, confirm
removals, or show results. PDF merge and Make PDF from multiple images open a
page-order window.

<img src="docs/images/compress-en.png" width="420" alt="The Custom Size panel for Compress with a 10 MB target, the largest selected file size, and the equivalent in bytes">

Batches still running after 0.8 seconds appear in **Activity**, without taking
focus from Finder. Use **Stop** to cancel an ordinary batch or pause HatchZip.
Closing the window leaves jobs running. Folder scans also show progress there.

<img src="docs/images/activity-run-en.png" width="420" alt="The MacEase Activity window compressing Long Trip.mov, with a progress bar and a stop button"><br>
<img src="docs/images/activity-done-en.png" width="420" alt="The MacEase Activity window after compressing, reading Done, with Undo and Show in Finder buttons">

With default settings, clean successes close automatically. Warnings, skipped
files, and failures remain when Activity is visible. A completion banner
appears when the result is not already retained there, if notifications are
enabled. Use **Show in Finder** or **Undo** where available. Recent batches
also appear in the menu bar with available actions such as **Undo** and
**Show in Finder**. HatchZip extraction has no Undo.

<img src="docs/images/menubar-en.png" width="318" alt="The MacEase menu bar menu with Results, a Recent list of batches where one is expanded to Undo and Show in Finder, then Settings, Check for Updates, and Quit MacEase">

---

## Conversion formats

| From | To |
| --- | --- |
| **PNG, JPEG, HEIC, WebP, AVIF, JPEG XL, GIF, TIFF, BMP, TGA, ICO, ICNS, SVG** | Any other format in this row, or PDF |
| **PSD** | PNG, JPEG, TIFF |
| **Camera RAW** | Any image format in the first row, or PDF |
| **Animated GIF, APNG, animated WebP** | GIF, APNG, animated WebP, keeping every frame |
| **HDR JPEG, HEIC, AVIF, JPEG XL, PNG** (single image) | SDR |
| Images → **Make PDF** / **Make Icon** | PDF / ICNS, ICO, AppIcon set |
| **MP4, MOV, M4V, MKV, WebM, AVI, FLV** | Any other format in this row |
| Video → **Convert** | GIF, animated WebP, APNG |
| Video → **Extract Audio** | M4A (AAC or ALAC), MP3, AAC, WAV, AIFF, FLAC, Ogg Vorbis, Opus |
| **HDR MP4, MOV, M4V** (including supported Dolby Vision 8.4 base layers) | SDR |
| **MP3, M4A (AAC or ALAC), raw AAC, WAV, AIFF, FLAC, Ogg Vorbis, Opus, CAF (PCM or ALAC)** | Any format in this row |
| Audio or video → **Subtitles** | SRT, WebVTT, plain text, translated SRT |
| **PDF** | PNG or JPEG pages, multipage TIFF, TXT |
| **DOCX, ODT, RTF, RTFD** | PDF, TXT |
| **HTML** | Source TXT, rendered TXT, PDF |
| **Markdown** | Source TXT, HTML, PDF |
| **CSV** | TXT, JSON, XML, HTML, Markdown |
| **JSON** | TXT, CSV, XML, XML or binary plist, YAML, TOML |
| **XML** | TXT, JSON |
| **INI, CFG, CONF** | TXT, JSON, XML |
| **YAML, TOML** | TXT, JSON |
| **XML or binary plist** | JSON |
| **SRT, WebVTT** | Source TXT, the other subtitle format |
| **Other recognized text files** | TXT, except files already classified as TXT |
| **Folder** | ZIP, 7z, TAR, tar.gz |
| **Local ZIP, 7z, TAR, tar.gz/tgz and recognized numeric split volumes** | HatchZip extraction; consumes the archive, no Undo |
| **RAR** | An extracted folder, retaining the archive |
| **JAR** | A folder of decompiled Java source |
| Text encodings | UTF-8, UTF-8 with BOM, UTF-16, Shift_JIS |
| Line endings | LF, CRLF |

AIFF-C input depends on its codec. Container support does not imply support
for every codec inside it. SDR-to-HDR conversion, WMA, AV1 video encoding, and
RAR creation are not implemented. Media operations act on selected files,
without scanning folders for media.

<details>
<summary><b>Limits and safeguards</b></summary>

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
Explicit **Convert > SDR** follows the selected output mode, checks the content,
and skips SDR inputs. Video edits in either output mode refuse multiple video
or audio tracks and streams they cannot preserve. Explicit exports keep the
source and report omitted streams.

</details>

[docs/SPEC.md](docs/SPEC.md) describes the target product, including acceptance
criteria that are not all verified on every supported macOS version.

---

## Settings

Open **Settings** from the menu bar icon. Changes apply immediately.

<img src="docs/images/settings-general-en.png" width="640" alt="MacEase Settings, General page, with Language, Launch at login, Notifications, the choice between Save as new file and Replace original, progress window options, Allow permanent delete, and Show Welcome Window">

- **General** – Language, launch at login, notifications, **Save as new file**
  or **Replace original**, the Activity window and when it closes, permanent
  deletion, and the Welcome window.
- **Finder Menu** – Show or hide each kind, operation, preset, and format, and
  edit resize and compression values, an extra rotation angle, and platform
  presets. Some formats and utilities are hidden by default.
- **Images**, **Video**, **Audio**, **Folders**, **Text**, and **Text
  Recognition & AI** – Quality, background, animation, audio, subtitle, OCR,
  PDF, folder, and text defaults, including duplicate matching and exclusion
  rules.
- **Advanced** – **Reset All Settings…** keeps history and edited platform
  presets.
- **About** – Version and **Third-Party Notices**.

<img src="docs/images/settings-finder-en.png" width="640" alt="MacEase Settings, Finder Menu page, with checkboxes for Images, Videos, Audio, PDFs, Text, Folders, Archives, JAR and All Files, Hide All and Show All buttons, and editable resize percentages and pixel sizes">

---

## Requirements

| Requirement | Details |
| --- | --- |
| **Mac** | Apple Silicon, macOS 26 or later |
| **Finder extension** | Enabled, for the right-click menu |
| **Apple Intelligence** | Enabled with its on-device model available, only for AI features. Other operations do not require it. |
| **Speech and Translation assets** | Supported, installed Speech language assets for transcription and Translation models for translated subtitles. MacEase reports missing assets. |
| **Java runtime** | Discoverable by macOS, only for JAR decompilation |

Processing runs on your Mac. The app checks GitHub for updates. Some Apple
features require installed language assets or models.

---

## FAQ

<details>
<summary><b>MacEase does not appear in the Finder menu</b></summary>

Enable the Finder extension from the Welcome window or
**System Settings > General > Login Items & Extensions**. While it is off after
setup, the menu bar icon shows an attention badge. Some items appear only for
matching selections, and some formats and utilities are hidden by default;
**Settings > Finder Menu** shows them.

</details>

<details>
<summary><b>Where do the new files go?</b></summary>

Next to their sources, in the same folder. If a name is taken, MacEase adds a
number instead of overwriting. With **Replace original**, MacEase verifies the
result before moving the original to the Trash. **Extract with HatchZip** instead
consumes the archive in place without confirmation; it does not keep an original.

</details>

<details>
<summary><b>Can I undo an operation?</b></summary>

Yes. Use **Undo** in Activity, in the completion banner, or under **Recent** in
the menu bar. Undo moves created outputs to the Trash or restores replaced
originals. Removals go to the Trash unless you allow and confirm permanent
deletion, which cannot be undone. **HatchZip extraction also has no Undo**, and
starts without confirmation. Paused HatchZip sessions support Resume, not
restoration of the original archive.

</details>

<details>
<summary><b>Why does macOS block MacEase on first launch?</b></summary>

Release builds use a self-signed certificate and are not notarized by Apple.
Follow steps 3 and 4 of [Installation](#installation), or build from source.

</details>

<details>
<summary><b>Does MacEase upload my files?</b></summary>

No. Processing runs on your Mac. The app checks GitHub for updates, and macOS
may download Speech, Translation, or Apple Intelligence assets that those
features require.

</details>

---

## Build from source

Requirements: Apple Silicon Mac, macOS 26 or later, Xcode 26 or later,
Homebrew, and Rust 1.93 or later (including Cargo). `make bootstrap` installs
XcodeGen, CMake, Meson, Ninja and pkg-config, and installs Rust if Cargo is
missing. Update an older Rust toolchain before building. Xcode 27 is required
to build macOS 27-specific features.

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

### Architecture

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
Matroska and WebM containers, and SVG tracing. A pinned Rust helper uses
**hatchzip-core 0.1.8** under its MIT license for in-place extraction, with
UnRAR disabled; ordinary RAR extraction uses libarchive.

Details: [docs/SPEC.md](docs/SPEC.md) and [docs/adr/](docs/adr/).

---

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
toml++'s MIT license and the MIT license used for hatchzip-core. Their license
texts are included with the native library notices in the app's `THIRD_PARTY_NOTICES.txt`.
Open **Settings > About > Third-Party Notices** to read them.
