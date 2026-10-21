# MacEase v1 Specification

This document is the single source of truth for MacEase v1. It describes the
finished product. When code and this document disagree, this document wins;
when a decision changes, update this document, its Changelog, and add an ADR
under `docs/adr/`.

## 1. Overview

MacEase is a macOS toolkit that converts, compresses, resizes and otherwise
transforms files entirely from the Finder right-click menu. The user selects
files in Finder, opens the context menu, picks an operation, and the files are
transformed in place. There is no main window workflow.

Principles:

- **Right-click and done.** Every operation starts from the Finder context
  menu. Operations with no choices run immediately. Small panels appear only
  when an operation needs input.
- **Never lose a file.** An original is never modified or removed until the
  output is fully written and verified. Replaced originals go to the Trash and
  every batch can be undone.
- **Local only.** All processing is on-device. No telemetry. The network is
  used only for the update check and for OS-managed model and asset downloads.
- **Native.** Apple frameworks first, permissive C libraries where Apple has no
  encoder, and in-house Swift implementations where no permissive library
  exists.

This specification is the complete v1 feature list. Comparison with other tools
is not an acceptance criterion.

## 2. Platform and tooling

| Item | Decision |
| --- | --- |
| OS | macOS 26.0 or later |
| Hardware | Apple Silicon only (arm64) |
| Language | Swift 6 language mode, strict concurrency |
| UI | SwiftUI for panels and settings, AppKit for app lifecycle, menu bar and Finder Sync |
| Xcode | Xcode 27 for release builds (macOS 27 SDK); the code must also build with Xcode 26.x |
| Project | XcodeGen `project.yml` committed; `.xcodeproj` is generated and ignored |
| Core logic | Local Swift package `Packages/MacEaseKit`, tested with `swift test` |
| Formatting and lint | `swift format` (bundled with the toolchain) with the committed `.swift-format`; warnings are errors |
| License | MIT |
| UI languages | English and Japanese |

APIs that exist only in the macOS 27 SDK live in one file per feature, wrapped in
`#if compiler(>=6.4)` and `#available(macOS 27, *)`, so the project builds with
Xcode 26 and runs on macOS 26.

## 3. Architecture

### 3.1 Components

| Component | Bundle ID | Sandbox | Role |
| --- | --- | --- | --- |
| `MacEase.app` | `io.github.tky27.MacEase` | No | Menu bar agent (`LSUIElement`). Receives requests, runs jobs, shows panels, progress, notifications, settings, onboarding. Writes the menu file. |
| `MacEaseFinderSync.appex` | `io.github.tky27.MacEase.FinderSync` | Yes (required for extensions) | Reads the menu file, builds the context menu, forwards the chosen entry and selection to the host by URL. Performs no file I/O on the selection. |

Debug builds use the bundle ID suffix `.dev`, the display name `MacEase Dev`,
the URL scheme `macease-dev` and the support folder `MacEase Dev`, so a
development build and an installed release never register duplicate menus.

`Packages/MacEaseKit` targets:

| Target | Linked by | Contents |
| --- | --- | --- |
| `MenuCatalog` | App, extension | File kind classification by extension, operation and preset identifiers, menu file model (Codable), entry index encoding. No AppKit, no file I/O beyond reading the menu file. |
| `Formats` | Engine | In-house encoders, decoders and containers (section 3.8). Pure Swift plus the native libraries. |
| `Engine` | App | Operations, job queue, file commit, history, presets, settings model, Apple framework integration. |
| Native binary targets | Formats, Engine | xcframeworks built by `scripts/build-deps.sh` (section 3.7). |

### 3.2 Repository layout

```
App/                      Host app sources, assets, Info.plist, entitlements, String Catalogs
FinderSync/               Finder Sync extension sources, Info.plist, entitlements, String Catalog
Packages/MacEaseKit/      Swift package (MenuCatalog, Formats, Engine) and its tests
Vendor/deps.lock          Pinned native dependency versions, URLs and SHA-256
Vendor/patches/           Patches applied to native dependency sources, if any
scripts/                  build-deps.sh, make-dmg.sh, create-signing-identity.sh,
                          generate-notices.sh, bench.sh
docs/                     SPEC.md, adr/, spikes.md
project.yml               XcodeGen project
Makefile                  Developer entry points (see AGENTS.md)
```

### 3.3 Extension and host protocol

**Menu file.** The host writes `~/Library/Application Support/MacEase/menu.json`
(mode 0600) at launch and whenever settings, language or capability
availability change. The extension reads it through the sandbox entitlement
`com.apple.security.temporary-exception.files.home-relative-path.read-only`
with the value `/Library/Application Support/MacEase/` (debug:
`/Library/Application Support/MacEase Dev/`). Verified in the spike (see
`docs/spikes.md`). The extension re-reads the file only when its modification
date changes.

Menu file content:

```json
{
  "schema": 1,
  "catalogVersion": "sha256 of the entries array",
  "token": "64 hex characters",
  "hostAvailable": true,
  "entries": [
    { "op": "image.resize", "preset": "percent-50", "kind": "image", "path": ["Resize", "50%"] }
  ],
  "kinds": { "image": { "title": "Images" } }
}
```

- `entries` lists every visible menu leaf, already localized in the host's UI
  language and already filtered by settings and capabilities (hidden items,
  Apple Intelligence availability, Java availability).
- `path` gives the localized submenu titles from the kind level down to the leaf.
- `token` is generated once from 32 random bytes on first launch, persisted by
  the host, and rotatable in Settings > Advanced.

If the menu file is missing or unreadable, the extension shows a single item,
"Open MacEase", which launches the host.

**Menu construction.** Finder Sync copies menu items and keeps only title,
image, action and `tag`; `representedObject` is lost (verified). Each leaf's
`tag` is its index in `entries`. Action handlers run off the main thread
(verified: isolating the class to the main actor crashes the extension). They
only read `sender.tag`, read the selection from `FIFinderSyncController`, build
the URL, and call `NSWorkspace.shared.open`.

**Request URL.**

```
macease://run?v=<catalogVersion>&e=<entryIndex>&t=<token>&path=<path>&path=<path>…
```

- Built with `URLComponents` and `URLQueryItem`. Verified with 5,000 paths
  (670 KB URL) containing `&`, `#`, `%` and Japanese characters.
- The host processes URLs in `NSApplicationDelegate.application(_:open:)`,
  including the URL that launches it.
- The host rejects a request whose token does not match, logs it, and shows
  nothing else. A request whose `v` differs from the current catalog version is
  rejected with a notification asking the user to retry.
- For a container menu (right-click on a folder background), the single path is
  `FIFinderSyncController.targetedURL()`.

**Threat model.** The token stops web pages and documents from triggering
operations through the URL scheme. Local processes running as the same user can
already modify the user's files and are out of scope. Permanent deletion is
never triggered directly by a URL; it always passes through a confirmation panel.

### 3.4 Job engine

- A request becomes a **batch** of **items** (one per input file, or one item
  for multi-input operations such as PDF merge or archive creation).
- Items run concurrently up to `max(1, activeProcessorCount / 2)` for CPU-bound
  work. Hardware video encodes (VideoToolbox H.264, HEVC, HEVC with alpha) run
  one at a time. Software encodes (libvpx, libaom, ProRes on chips without a
  ProRes engine) count as CPU-bound.
- Each item reports progress in [0, 1]. Batches can be cancelled from the menu
  bar; cancellation stops running items, removes their staging files and leaves
  originals untouched.
- Each item ends as `succeeded`, `skipped(reason)` or `failed(error)`. One item
  failing never stops the rest of the batch.

### 3.5 File commit model

Every operation has exactly one output mode:

| Mode | Behavior |
| --- | --- |
| **Replace** | The output takes the original's place. The original goes to the Trash. |
| **Derived** | New files or folders are created next to the original. The original is kept. |
| **Rename** | The file is renamed. No content changes. |
| **Clipboard** | The result is copied to the pasteboard. No files change. |
| **Report** | The result is shown in a panel, optionally saved as a derived file. |
| **Trash** | Items confirmed in a panel are moved to the Trash (or deleted permanently when that setting is on). |

**Staging.** Outputs are written to a directory obtained from
`FileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: original, create: true)`,
which is on the same volume and outside the user's folder (so cloud-synced
folders never see partial files). Staging is removed on success, failure and
cancel. Stale staging directories from a crash are removed at host launch.

**Verification before commit.** The output must be non-empty and must open with
the decoder for its type (ImageIO source with at least one image, AVAsset with
a playable track or the in-house demuxer, archive listing, PDFDocument, valid
UTF-8 or target encoding for text).

**Replace sequence.**

Before an operation reads a non-directory input, the engine records its size
and modification date. Folder inputs are not stamped: folders never replace.
Replacement commit sections and their history records are serialized. Within
one coordinated write, the engine compares the current input stamp with that
scan stamp before cloning, Trashing or replacing the original; a changed input
is skipped as `changedSinceScan`.

1. If the output name equals the original name: clone the original
   (`clonefile`, falling back to copy on non-APFS volumes) into the item's
   staging directory under its own name, move the clone to the Trash with
   `trashItem` and record the resulting URL, then
   `FileManager.replaceItemAt(original, withItemAt: output)` (ADR 0007).
2. If the output name differs (extension changes): move the output to its final
   name next to the original, then move the original to the Trash and record the
   resulting URL. A crash between the steps leaves both files, never neither.
3. On volumes without a Trash (`trashItem` throws `NSFeatureUnsupportedError`),
   the original is kept and the output is committed as a derived file.

A case-only output name on a case-insensitive volume uses the same-name
replacement sequence, followed by a case-change move. If that move fails, the
replacement remains committed at the original name with a warning and its
Trash URL recorded. A failure to stamp any committed output must not discard
its history record; undo skips an output whose stamp is unavailable.

All commits go through `NSFileCoordinator` so iCloud Drive and File Provider
locations stay consistent; reading a dataless cloud file downloads it first.

**Names.** A derived output or a renamed replace output that collides with an
existing name gets ` (2)`, ` (3)` and so on before the extension.

Report Save and Analyze Export as Markdown use a save panel to choose a folder
and name. They stage and verify UTF-8 text, then use the Derived commit path
and record an undoable batch. Existing files are never overwritten, including
after a save panel replacement confirmation. Collisions use the available-name
rule, and the host tells the user the final name when it changed.

**Preservation on replace.**

- Creation date, modification date, Finder tags and Finder comment are copied
  to the output.
- EXIF, XMP, IPTC and the ICC profile are copied when the output format can hold
  them, and dropped silently when it cannot (BMP, ICO, GIF, SVG). Metadata strip
  operations are the exception.
- Pixel rotation sets EXIF Orientation to 1.
- ISO HDR gain maps are kept for HEIC and JPEG outputs through ImageIO auxiliary
  data. Other targets tone-map to SDR.
- Platform presets remove GPS data by default (setting).

**Deletions.** Duplicate and empty-folder removal move items to the Trash by
default. Permanent deletion is an opt-in setting and always asks for
confirmation in a panel.

### 3.6 History and undo

- History is persisted in `~/Library/Application Support/MacEase/history.json`
  and keeps the last 100 batches.
- Each record holds the operation, time, and per item: original path, Trash URL
  (replace), output path, rename old and new names, and a commit-time output
  stamp. File stamps contain size and modification date. Rename stamps also
  contain filesystem device and inode identity. Replace and removal records
  include a Trash stamp with device, inode, size and modification date, captured
  while the commit holds its naming lock. Folder Trash stamps include the
  bounded summary described below.
- Replace, derived and rename output stamps are captured inside the same
  coordinated write and naming lock as their mutations, and returned with the
  commit results. Later edits must not become the undo baseline. A stamp failure
  still records the committed output with an unavailable stamp.
- Folder stamps contain a bounded summary, never a persisted descendant list:
  descendant count, total size, latest modification date, and an
  enumeration-order-independent hash of relative paths, types, sizes,
  modification times and modes. Symbolic links are not followed. Unreadable
  children contribute path/error markers and an unreadable count; an
  incomplete summary cannot authorize undo. Root stamp failures leave a
  record without a stamp. Summaries scan descendants without retaining them.
- Undo refuses a batch that is still running, without consuming any entries.
  The menu hides Undo until that batch finishes. Appending new entries resets
  the record's undone flag so pending entries cannot be hidden.
- Undo and commits share one gate. Each undo item holds the committer's naming
  lock and coordinates all affected paths together. Stamp and occupancy checks,
  moves and rollback run inside that single exclusive write section.
- Undo works per batch. For each item it moves the original back from the Trash
  and moves the output to the Trash (replace), moves derived outputs to the
  Trash (derived), or renames back (rename). An item is skipped with a reason
  when its Trash URL no longer exists, its Trash identity or metadata changed,
  its Trash stamp is missing, the original name is occupied, or its output
  stamp changed, is missing or cannot be verified. Legacy replace and removal
  records without Trash identity stamps load but cannot restore files. A case-only replace
  must not mistake its own output for an occupied original name.
- Rename undo also skips a different filesystem identity, even with matching
  size and modification date. Legacy rename records without stamps and legacy
  folder records without summaries load but are skipped. File stamps do not
  hash contents; edits preserving both size and modification date are outside
  their detection guarantee.
- An undo attempt consumes restored and skipped entries; only failed entries
  remain retryable in that batch.
- Replace and removal records are saved without throttling before the commit
  gate is released. Other records may be coalesced for up to one second and
  are flushed at batch completion. Failed saves remain dirty for retry.
- Normal application termination stops new requests, cancels pending work and
  waits for accepted undo requests. An engine termination barrier then waits
  for the current commit and its record, seals further commits and undo, and
  flushes history. AppKit defers termination until this completes off the main
  actor. A flush failure cancels termination and allows a retry. Forced process
  termination and crashes cannot provide this orderly shutdown guarantee.
- The completion notification offers **Undo** and **Show in Finder**. The menu
  bar shows the last 10 batches with Undo.
- A batch produces one notification, whatever its size.

### 3.7 Native dependencies

All are permissively licensed and compatible with MIT distribution. Versions are
the latest stable release at implementation time, pinned by version, source URL
and SHA-256 in `Vendor/deps.lock`. `scripts/build-deps.sh` downloads, verifies,
builds arm64 static libraries with deployment target 26.0 and packages them as
xcframeworks into `Vendor/build/` (ignored by git, cached in CI).
`Package.swift` fails with a message pointing to the script when they are missing.

| Library | License | Purpose | Build notes |
| --- | --- | --- | --- |
| libwebp (+ libsharpyuv, demux, mux) | BSD-3-Clause | WebP and animated WebP encode and decode, ICC via WebPMux | CMake |
| libavif | BSD-2-Clause | AVIF encode and decode | CMake, with dav1d and libaom |
| libaom | BSD-2-Clause + AOM Patent License 1.0 | AV1 encoding for AVIF stills | CMake |
| dav1d | BSD-2-Clause | AV1 decoding (AVIF fallback, AV1 video on chips without hardware AV1) | Meson and Ninja |
| libjxl (+ highway, brotli, skcms) | BSD-3-Clause, Apache-2.0 (highway), MIT (brotli), BSD-3-Clause (skcms) | JPEG XL encoding | CMake, bundled third_party at the commits libjxl pins |
| libvpx | BSD-3-Clause + patents | VP8 and VP9 encode and decode, including alpha | configure with an explicit `--target=arm64-darwin*-gcc` |
| libopus | BSD-3-Clause | Opus encode and decode | CMake |
| libogg, libvorbis | BSD-3-Clause | Ogg paging, Vorbis encode and decode | CMake |
| libFLAC | BSD-3-Clause | FLAC encode | CMake, library only (the command line tools are GPL and are not built) |
| libarchive | BSD-2-Clause | Archive read and write | CMake with zlib and bzip2 from the SDK, plus xz (0BSD) and zstd (BSD); iconv, libxml2, expat and OpenSSL off |
| xz (liblzma), zstd | 0BSD, BSD-3-Clause | libarchive codecs | CMake |
| libdeflate | MIT | Optimized DEFLATE for PNG and ZIP | CMake |
| CFR | MIT | JAR decompilation (bundled `cfr.jar`, run with the user's Java) | Downloaded jar |

`scripts/generate-notices.sh` builds `THIRD_PARTY_NOTICES.txt` from
`Vendor/deps.lock` and the license and patent files of each source. The app
shows it in Settings > About.

**Clean-room rule.** Do not open, copy or translate source code from GPL, LGPL
or AGPL projects, including FFmpeg, LAME, gifski, pngquant, libimagequant and
Clop. Use published specifications and papers instead.

### 3.8 In-house formats

Each component lives in `Formats` and has its own tests. SSIM is computed on
the luma channel against the source.

| Component | Scope | Algorithm | Done when |
| --- | --- | --- | --- |
| MP3 encoder | MPEG-1 Layer III, 44.1 and 48 kHz, mono and stereo with M/S, CBR 128/192/256/320 kbps and VBR quality 0–9 | Written from ISO/IEC 11172-3: polyphase filterbank, MDCT with window switching, psychoacoustic model with masking thresholds, bit reservoir, Huffman coding | AudioToolbox decodes every frame without error; on the music fixture at 192 kbps the segmental SNR is at least 20 dB and bandwidth is at least 16 kHz; encoding runs at least 20× real time on M1 |
| GIF encoder | Single and animated | Color quantization in Oklab (Wu initial palette refined by k-means), global or per-frame palettes, Floyd–Steinberg or ordered dithering (setting), transparent-pixel frame differencing, LZW | ImageIO decodes it; SSIM ≥ 0.93 on the gradient video fixture at 256 colors with dithering; output is smaller than ImageIO's GIF output for the same frames |
| PNG lossy quantizer | RGBA to ≤ 256-color palette with alpha (tRNS) | k-means in premultiplied Oklab with alpha, optional dithering, libdeflate compression with per-row filter selection | SSIM ≥ 0.97 and size ≤ 45% of lossless libdeflate PNG on the photo fixture |
| PNG lossless optimizer | Re-encode PNG without changing pixels | Bit depth and color type reduction, filter selection, libdeflate level 12 | Decoded pixels identical; never larger than the input (otherwise keep input bytes) |
| Matroska and WebM | Demux and mux; video H.264, HEVC, VP8, VP9, AV1; audio AAC, Opus, Vorbis, FLAC, MP3, AC-3, PCM; BlockAdditions for VP9 alpha; Cues and SeekHead | Per the Matroska specification (RFC 9559) and the WebM container guidelines | Round-trip mux and demux preserves packets and timestamps; Chrome-compatible WebM (VP9 + Opus) plays in WKWebView; AVFoundation-independent tests pass |
| AVI | Demux (OpenDML included); mux MJPEG + PCM | Microsoft AVI RIFF specification | Files from common encoders open; MJPEG + PCM output opens in QuickTime-compatible players |
| FLV | Demux; mux H.264 + AAC | Adobe FLV specification v10.1 | Round-trip preserves packets and timestamps |
| ICO | Write with PNG-compressed entries 16–256 px; read | Microsoft ICO format | ImageIO reads every entry |
| ICNS | Write with PNG payloads (`ic07`–`ic14`); read | Apple ICNS format | ImageIO and NSImage read every size |
| SVG tracer | Monochrome and up to 8 colors | k-means color layers, marching squares contours, Douglas–Peucker simplification, cubic Bézier fitting (Schneider), stacked filled paths | Re-rasterized intersection-over-union ≥ 0.95 per color layer on the logo fixture |
| Target-size planner | Images, GIF, video, audio | See section 8.10 | Output ≤ target and ≥ 92% of target on the fixtures |

Ogg pages use libogg; the in-house code only arranges packets and granule positions.

## 4. Finder menu

### 4.1 Scope

- `directoryURLs` is `/`, which covers every mounted volume (verified for
  local folders; external and network volumes are checked during
  implementation and added explicitly if Finder requires it).
- Item menu: `contextualMenuForItems`. Container menu (right-click on a folder's
  background): `contextualMenuForContainer`, showing folder operations for the
  targeted folder.
- `menu(for:)` must return within 30 ms for 1,000 selected items. The extension
  classifies by filename extension only, using the `MenuCatalog` table. The host
  re-checks the real content type and skips mismatched items with a reason.

### 4.2 Structure

- One top-level item **MacEase ▸** (verified to appear at the top level of the
  context menu, not inside Quick Actions).
- Single-kind selection: `MacEase ▸ <Operation> ▸ <Preset>`.
- Mixed selection: `MacEase ▸ <Kind> (n) ▸ <Operation> ▸ <Preset>`. Four levels
  are verified.
- Operations without choices are leaves. Operations with choices end with a
  separator and **Custom…**, which opens a panel.
- Kinds: Images, Videos, Audio, PDFs, Text, Archives, JAR, Folders. Operations
  available for any file (checksum) appear under **All Files** in mixed
  selections and at the end of single-kind menus.
- Hidden operations (Settings > General > Menu Items) are not written to the
  menu file. Apple Intelligence items are written only when
  `SystemLanguageModel.default.availability` is `.available`. JAR items are
  written only when a Java runtime is found with `/usr/libexec/java_home`.

### 4.3 Classification

| Kind | Extensions |
| --- | --- |
| image | jpg, jpeg, jpe, png, apng, heic, heif, hif, avif, jxl, webp, gif, tif, tiff, bmp, ico, icns, svg, dng, cr2, cr3, nef, arw, raf, orf, rw2 |
| video | mp4, m4v, mov, mkv, webm, avi, flv |
| audio | mp3, m4a, aac, wav, aif, aiff, flac, ogg, oga, opus, caf |
| pdf | pdf |
| text | txt, csv, tsv, json, xml, ini, cfg, conf, md, log, yaml, yml |
| archive | zip, 7z, tar, gz, tgz, bz2, xz, rar |
| jar | jar |
| folder | directories (packages such as `.app` are treated as files and get only All Files operations) |

## 5. Panels

Panels are small SwiftUI windows opened by the host, centered on the active
screen, always in front, dismissed with Esc. Each remembers its last values per
operation.

| Panel | Used by | Contents |
| --- | --- | --- |
| Size | resize (image, video), icon set | Mode (percent, width, height, fit box, long edge), value fields, aspect lock, preview of resulting dimensions for the first file |
| Target size | compress (all kinds) | Size in MB (decimal) or quality slider, platform preset picker, options (allow downscale, allow fps reduction, strip GPS) |
| Angle | rotate | Angle field and dial, fill (transparent or color) |
| Trim | video and audio trim, LINE preset over the limit | AVPlayerView trimming UI for MP4, MOV, M4V and audio; for MKV, WebM, AVI and FLV a thumbnail strip (one frame every 1/20 of the duration) with numeric start and end fields; exact or keyframe mode |
| Frame picker | thumbnail, GIF range | Same media view as Trim with a single playhead |
| GIF options | video to GIF, animated WebP, APNG | Range, width, fps, colors, dithering, loop, estimated size |
| Background | image and video background | Mode (subject, person; color key with eyedropper and tolerance for images only), output (transparent, green #00B140, blue #0047BB, custom color, blur radius), video output format |
| Page order | PDF merge, images to PDF | Thumbnails with drag to reorder, remove |
| Page select | PDF extract | Page range field and thumbnails |
| Rename | batch rename | Prefix, suffix, find and replace, numbering (start, step, digits), date (creation or EXIF), live preview table |
| AI rename | AI rename | Suggested names table, editable, apply all or selected |
| Duplicates | remove duplicates | Groups with keep-one selection, total reclaimable size, Trash or permanent |
| Empty folders | remove empty | List with checkboxes |
| Analyze | analyze folder | Total size, file count, largest 50 files, size by type chart, duplicate and empty summaries, export as Markdown |
| Text result | OCR, checksum, tree | Read-only text with Copy and Save |
| Password | archive extract | Secure field, remember for this batch |
| Custom (AI) | natural-language custom | Prompt field, parsed plan shown as operation and parameters, Run |
| Subtitles | video subtitles | Spoken language, format (SRT, VTT, TXT), optional translation target |
| Extract audio | extract audio | Format, bitrate for lossy formats (Automatic copies the stream when possible) |

## 6. Progress and notifications

- A menu bar extra shows an icon that animates while jobs run, a list of active
  batches with progress and Cancel, the last 10 batches with Undo, Settings,
  Check for Updates and Quit.
- `UserNotifications` sends one notification per batch on completion: success
  count, skipped and failed counts with the first reason, actions **Undo** and
  **Show in Finder**. Failures-only batches use a failure title.
- Notification permission is requested during onboarding. Without it, results
  are visible in the menu bar only.

## 7. Settings

SwiftUI settings window with these tabs. Every value has a default and is stored
in the host's `UserDefaults`, except presets (section 9).

| Tab | Settings |
| --- | --- |
| General | Language (System, English, Japanese; changing asks, then relaunches the host), launch at login (`SMAppService.mainApp`), notifications, menu item visibility per operation, permanent delete opt-in |
| Images | Default quality per format (JPEG, HEIC, WebP, AVIF, JXL), PNG compression (lossless optimize on convert), GIF dithering, metadata fields to strip (EXIF, GPS, maker notes, comments, XMP, IPTC), keep GPS on platform presets, color key default and tolerance, background colors |
| Video | Codec for re-encode (Auto, H.264, HEVC), quality mode (speed or quality), allow downscale and fps reduction in target-size compression, trim mode default (keyframe or exact), rotation fill color, GIF defaults, background output format default |
| Audio | Default bitrate per format, MP3 mode (CBR or VBR), loudness target (−14, −16, −23 LUFS), extract audio default format |
| Folders | Duplicate matching (size and hash then byte compare; option to ignore hidden files), excluded folder names (`.git`, `node_modules`, `.Trash`, user-added), empty folder definition (ignore `.DS_Store`), rename defaults, archive format default, exclude `.DS_Store`, `__MACOSX` and AppleDouble files from new archives |
| Text | Unmappable character policy for Shift_JIS (fail, `?`, numeric character reference), JSON indent (2, 4, tab), key sort scope (recursive or top level), CSV type inference |
| OCR & AI | OCR languages and output default (clipboard, file, panel), subtitle language and output format, translation target language, AI features on or off |
| Presets | Platform preset editor (section 9) with reset to defaults |
| Advanced | Concurrency limit, rotate URL token, clear history, open logs, Copy Diagnostics (versions, OS, recent log lines), Full Disk Access shortcut |
| About | Version, links, license, third-party notices |

## 8. Operations

Columns: **ID** is the stable operation identifier. **Mode** is the commit mode
from section 3.5. Presets listed are the menu leaves; every operation with
presets also has **Custom…**.

### 8.1 Images

Inputs: everything ImageIO decodes (including HEIC, AVIF, JXL, WebP, RAW and
DNG), plus SVG rendered by WKWebView with a content rule list that blocks every
network load, plus ICO and ICNS via the in-house readers when ImageIO fails.

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `image.resize` | 25%, 50%, 75%, long edge 1080, 1920, 2560, 3840 | Replace | Lanczos via Core Image; keeps format, metadata and every animation frame; never upscales unless Custom asks for it |
| `image.compress` | Discord, X, Instagram, Email, Web, High, Medium, Low quality | Replace | Size targets per section 8.10; quality presets map to per-format quality values; PNG uses lossy quantization; keeps format unless the preset requires another (Instagram requires JPEG) |
| `image.convert` | PNG, JPEG, HEIC, WebP, AVIF, JPEG XL, GIF, TIFF, BMP, ICO, ICNS, SVG, PDF | Replace (Derived for RAW and DNG inputs) | Animated inputs keep all frames when the target holds animation (GIF, PNG written as APNG, WebP), otherwise frame 0 with a warning; multi-page TIFF to PDF keeps all pages, other targets use page 1; SVG output uses the tracer (Custom chooses colors) |
| `image.rotate` | 90° right, 90° left, 180°, Custom | Replace | Multiples of 90° on JPEG change only the orientation tag (lossless); other angles rotate pixels with transparent corners, or the fill color when the format has no alpha |
| `image.flip` | Horizontal, Vertical | Replace | Pixel flip, orientation reset to 1 |
| `image.trimBorders` | — | Replace | Removes uniform borders matching the corner color within tolerance |
| `image.background` | Remove, Green back, Blue back, Custom color, Blur, Color key | Replace | Subject mask from Vision `GenerateForegroundInstanceMaskRequest` (all instances), person mask option, or color key with tolerance; mask edges feathered 1 px; Remove outputs alpha and converts to PNG when the source format has no alpha (JPEG, BMP) |
| `image.stripMetadata` | All, GPS only, Settings selection | Replace | Pixels untouched for JPEG (`CGImageDestinationCopyImageSource`), PNG and TIFF (stored pixels with new metadata); HEIC re-encodes at the settings quality because macOS keeps its metadata otherwise (ADR 0010) |
| `image.ocr` | Copy text, Save as .txt, Show | Clipboard, Derived, Report | Vision `RecognizeTextRequest` accurate, language correction on, languages from settings with automatic detection |
| `image.toPDF` | — | Derived | One PDF from all selected images in Finder order; Page order panel when more than one image |
| `image.iconSet` | macOS icon (.icns), iOS AppIcon set, Windows icon (.ico) | Derived | Non-square inputs are padded to square with transparency; AppIcon set writes `Contents.json` and the sizes Xcode 26 expects |
| `image.copyBase64` | — | Clipboard | `data:` URI with the correct MIME type; refuses files over 10 MB |
| `image.aiRename` | — | Rename | Section 10 |
| `image.aiCustom` | — | Depends on plan | Section 10 |

### 8.2 Videos

Containers: MP4, M4V, MOV through AVFoundation; MKV, WebM, AVI, FLV through
the in-house demuxers. Video codecs: H.264, HEVC, ProRes, MPEG-4 Part 2 and
MJPEG through VideoToolbox; VP8 and VP9 through libvpx; AV1 through VideoToolbox
when `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)` is true, otherwise
dav1d. Audio codecs: AAC, MP3, PCM, ALAC, AC-3 through AudioToolbox; Opus and
Vorbis through libopus and libvorbis; FLAC through AudioToolbox. Unsupported
codecs (DTS, WMA, WMV, Sorenson H.263, VP6, Screen Video, RealVideo) fail with
a message naming the codec.

Replace operations refuse inputs with more than one video track or more than
one audio track before writing an output, because the current pipeline selects
only the first track of each kind. Derived operations may use those first tracks.

Resize, flip, frame-rate changes and exact trim preserve input alpha when
re-encoding MOV through HEVC with alpha or ProRes 4444, and WebM through VP9
with alpha. Other containers reject these alpha re-encodes before writing;
stream-copy edits retain their existing alpha (ADR 0010).

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `video.resize` | 50%, 2160p, 1080p, 720p, 480p | Replace | Re-encodes video with the source codec family when it is H.264 or HEVC, otherwise the settings codec; audio is copied |
| `video.trim` | — (panel) | Replace | Keyframe mode copies streams and starts at the keyframe at or before the mark; exact mode re-encodes |
| `video.compress` | Discord, X, Instagram Reels, LINE, Email, 10 MB, 25 MB, 50 MB, 100 MB, High, Medium, Low quality | Replace | Section 8.10; platform presets output MP4 with H.264 High and AAC; generic presets use HEVC (`hvc1`) in the source container when it supports HEVC, else MP4 |
| `video.rotate` | 90° right, 90° left, 180°, Custom | Replace | Multiples of 90° in MP4 and MOV set the track transform without re-encoding; other angles and containers re-encode with the fill color |
| `video.flip` | Horizontal, Vertical | Replace | Re-encode |
| `video.fps` | 24, 30, 60 | Replace | Frame dropping or duplication by timestamp; re-encode |
| `video.removeAudio` | — | Replace | Remux without audio tracks |
| `video.convert` | MP4, MOV, M4V, MKV, WebM, AVI, FLV | Replace | Remux when the target container holds the source codecs; otherwise MP4, MOV, M4V and FLV use H.264 or HEVC with AAC, MKV uses H.264 and AAC, WebM uses VP9 and Opus, AVI uses MJPEG and PCM |
| `video.toGIF` | 480 px 10 fps, 480 px 15 fps, 720 px 15 fps, X (15 MB) | Derived | In-house GIF encoder; X preset respects 15 MB, 1280×1080 and 350 frames |
| `video.toAnimatedWebP` | 480 px 15 fps, 720 px 24 fps | Derived | libwebp animation encoder |
| `video.toAPNG` | 480 px 15 fps | Derived | ImageIO APNG writer |
| `video.thumbnail` | First frame, Middle frame, Choose… | Derived | PNG or JPEG per settings, full resolution |
| `video.extractAudio` | MP3, M4A, AAC, WAV, AIFF, FLAC, OGG, Opus | Derived | Copies the stream when the target holds the source codec, else encodes; a bitrate chosen in the Custom panel always encodes |
| `video.subtitles` | SRT, VTT, TXT, Translated SRT | Derived | Speech framework `SpeechAnalyzer` with `SpeechTranscriber` and audio time ranges; language from settings or the system locale; cues split at sentence boundaries, at most 42 characters per line and 2 lines; translation with the Translation framework |
| `video.background` | Remove, Green back, Blue back, Custom color, Blur | Derived | Section 8.11 |
| `video.aiCustom` | — | Depends on plan | Section 10 |

### 8.3 Audio

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `audio.convert` | MP3, M4A (AAC), M4A (ALAC), AAC, WAV, AIFF, FLAC, OGG, Opus | Replace | Bitrates from settings; tags (title, artist, album, artwork) copied where the target supports them |
| `audio.compress` | 64, 96, 128, 192 kbps | Replace | Re-encodes in the same lossy format, or AAC in M4A for lossless sources and for MP3 below 128 kbps (ADR 0010) |
| `audio.normalize` | −14 LUFS, −16 LUFS, −23 LUFS | Replace | ITU-R BS.1770-4 integrated loudness; gain only, capped so the 4× oversampled true peak stays at or below −1 dBTP; the notification reports when the cap stopped short of the target |
| `audio.trim` | — (panel) | Replace | Sample-accurate for PCM and lossless; frame-accurate re-encode for lossy |
| `audio.aiCustom` | — | Depends on plan | Section 10 |

Inputs: MP3, AAC, M4A, ALAC, WAV, AIFF, CAF, FLAC, Ogg Vorbis, Opus. WMA is not supported.

Audio replacements preserve the source speaker layout whenever the output
encoder can represent it. Unsupported layouts fail before writing instead of
downmixing. The current MP3 and Opus implementations accept only mono and
stereo; multichannel Opus requires a future multistream implementation
(ADR 0010). AAC output supports at most six channels; raw ADTS output refuses
quadraphonic layouts. Unknown speaker layouts are rejected instead of being
interpreted solely from their channel count.

### 8.4 Folders

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `folder.removeDuplicates` | — (panel) | Trash | Candidates grouped by size, then SHA-256, then byte comparison; excluded folder names from settings; nothing is removed without the panel |
| `folder.removeEmpty` | — (panel) | Trash | Recursive; a folder containing only `.DS_Store` counts as empty by default |
| `folder.tree` | Copy, Save as .txt, Save as .md | Clipboard, Derived | Unicode box-drawing tree, folders first, sorted like Finder, excluded names skipped |
| `folder.rename` | — (panel) | Rename | Renames the selected items, or the folder's direct children when one folder is selected |
| `folder.aiRename` | — | Rename | Section 10 |
| `folder.analyze` | — | Report | Panel; Markdown export is Derived |
| `folder.compress` | ZIP, 7z, TAR, tar.gz | Derived | libarchive; one archive per selected folder, or one archive for a multi-item selection named after the parent folder |

### 8.5 Archives

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `archive.extract` | — | Derived | ZIP, 7z, TAR, gz, bz2, xz, tar.gz, RAR (read only) through libarchive into a new folder named after the archive (or into the parent when the archive has a single top-level folder); extraction flags `SECURE_NODOTDOT` and `SECURE_SYMLINKS`, absolute and `..` entry names refused before writing, `__MACOSX` skipped, quarantine copied from the archive, output capped at the larger of 1 GiB and 1000× the archive (ADR 0010); encrypted entries open the Password panel |

### 8.6 PDFs

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `pdf.merge` | — (Page order panel when needed) | Derived | One PDF from the selection in Finder order |
| `pdf.toImages` | PNG, JPEG | Derived | Folder of pages at 144 dpi (settable) |
| `pdf.toText` | — | Derived | `PDFDocument.string`, pages separated by form feed; scanned PDFs fall back to Vision OCR per page |
| `pdf.compress` | — | Replace | PDFKit write options `saveImagesAsJPEGOption` and `optimizeImagesForScreenOption`; kept only when smaller than the input |
| `pdf.rotate` | 90° right, 90° left, 180° | Replace | All pages |
| `pdf.extractPages` | — (panel) | Derived | Selected pages to a new PDF |
| `pdf.split` | — | Derived | One PDF per page in a folder |
| `pdf.aiRename` | — | Rename | Section 10 |

Quick Look already previews PDFs on macOS, so there is no preview operation.

### 8.7 Text

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `text.encoding` | UTF-8, UTF-8 with BOM, UTF-16, Shift_JIS | Replace | Input detection order: BOM, strict UTF-8, CP932, EUC-JP; ambiguous input asks in a panel; Shift_JIS means CP932 (`kCFStringEncodingDOSJapanese`) with the unmappable policy from settings |
| `text.lineEndings` | LF, CRLF | Replace | Mixed endings are normalized |
| `text.convert` | CSV→JSON, CSV→XML, CSV→HTML, CSV→Markdown, JSON→CSV, JSON→XML, XML→JSON, INI→JSON, INI→XML | Derived | CSV per RFC 4180 with delimiter detection among `,` `;` and tab, first row as header, strings unless type inference is on; XML→JSON maps attributes to `@name`, text to `#text`, repeated siblings to arrays; INI sections become objects and `;` and `#` start comments; JSON→CSV requires an array of flat objects and fails otherwise with the offending path |
| `text.json` | Pretty print, Minify, Sort keys | Replace | Key sort is lexicographic by Unicode scalar, recursive or top level per settings; invalid JSON fails with line and column |

### 8.8 JAR

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `jar.decompile` | — | Derived | Runs bundled `cfr.jar` with the Java found by `/usr/libexec/java_home` into a folder named after the JAR |

### 8.9 All files

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `any.checksum` | SHA-256, MD5 | Clipboard and Report | One line per file `hash  name`; Text result panel for more than one file |

### 8.10 Target-size compression

- Targets are in bytes. Preset limits are stored in decimal bytes and the target
  is `limit × 0.97`. Custom input is decimal megabytes.
- **Images (quality formats).** Binary search on quality between the format's
  minimum and maximum (at most 8 encodes). If the minimum quality is still too
  large and downscale is allowed, reduce dimensions by 10% steps and repeat.
- **PNG.** Lossless optimize, then lossy quantization with 256, 128 and 64
  colors, then downscale in 10% steps.
- **GIF.** Reduce fps, then width, then colors.
- **Video.** Plan in order and stop at the first output under target:
  1. Remux (container change only).
  2. Re-encode audio only (AAC 128 kbps, then 96, then 64).
  3. Re-encode video at the bitrate `(target × 8 / duration) − audio bitrate − 2% container overhead`.
  4. If the result misses, correct the bitrate by the ratio of target to actual
     size and encode once more.
     The correction aims at 96% of the target.
  5. If the required video bitrate falls below 0.04 bits per pixel per frame, or
     the corrected encode still misses, and downscale is allowed, step
     resolution down (2160p, 1440p, 1080p, 720p, 480p) and fps to at most 30,
     then plan again (ADR 0010).
- **Audio.** Choose the bitrate from target and duration among the format's
  supported bitrates.
- An item that cannot reach the target fails with the smallest achievable size
  in the message, and the original is kept.
- Accepted output: at most the target and at least 92% of the target on the
  fixtures, except when step 1 or 2 already lands below, and for AVIF and HEIC,
  whose quality steps are coarser than that band (ADR 0010).

### 8.11 Video background removal

- Mask source: Vision `GeneratePersonSegmentationRequest` (quality `.balanced`)
  for the Person mode, which is the default for video; Vision
  `GenerateForegroundInstanceMaskRequest` for the Subject mode, keeping the
  instance with the highest mask overlap with the previous frame.
- Temporal smoothing: exponential moving average of the mask with α = 0.6, then
  a 3 px feather.
- Outputs: transparent HEVC with alpha in MOV (default), ProRes 4444 in MOV,
  VP9 with alpha in WebM (BlockAdditions); or green, blue, custom color or
  blurred background in MP4 with H.264 or HEVC.
- Output name: `<name> (background removed).<ext>`.

## 9. Presets

Platform presets ship as `Packages/MacEaseKit/Sources/Engine/Resources/platform-presets.json`.
User edits are stored in `~/Library/Application Support/MacEase/platform-presets.json`
and win over the bundled file per preset ID. Settings > Presets can reset each
preset.

Schema: `{ "id", "name": {"en", "ja"}, "image": {...}?, "gif": {...}?, "video": {...}?, "audio": {...}? }`
with optional fields `maxBytes`, `maxWidth`, `maxHeight`, `maxFrames`,
`maxDurationSeconds`, `aspect` (`{"min": "4:5", "max": "1.91:1", "fit": "crop"}`,
fit `crop` or `letterbox`), `formats` (accepted formats; the source format is
kept when listed, otherwise the first is used), `videoCodec`, `audioCodec` and
`quality` (0 to 100).

Defaults (checked October 2026; values change, so they are editable):

| ID | Image | GIF | Video |
| --- | --- | --- | --- |
| `discord` | 20,000,000 B | 20,000,000 B | 20,000,000 B, MP4 H.264 + AAC |
| `x` | 5,000,000 B, JPEG/PNG/WebP | 15,000,000 B, ≤ 1280×1080, ≤ 350 frames | 512,000,000 B, ≤ 1920×1080, MP4 H.264 + AAC |
| `instagram` | 8,000,000 B, JPEG, width ≤ 1440, aspect 4:5 to 1.91:1 (crop) | — | Reels: 9:16 1080×1920 (crop default, letterbox option), MP4 H.264 + AAC |
| `line` | — | — | ≤ 300 s (longer inputs open Trim one second under the limit, then compress, ADR 0010), ≤ 1920×1080, MP4 H.264 + AAC |
| `email` | 18,000,000 B (25 MB attachment limit minus Base64 overhead) | 18,000,000 B | 18,000,000 B, MP4 H.264 + AAC |
| `web` | WebP, long edge ≤ 1920, quality 80 | — | — |

## 10. Apple Intelligence

Shown only when `SystemLanguageModel.default.availability == .available` and
AI features are on in settings. The host refreshes the menu file when
availability changes.

**Custom (natural language)** (`image.aiCustom`, `video.aiCustom`, `audio.aiCustom`). The user
writes a request such as "WebP under 1 MB, long edge 1600". A
`LanguageModelSession` with guided generation (`@Generable` plan of one to
three steps, each an operation ID and one of its menu presets) turns it into a
plan restricted to the operations of the selected kind (ADR 0010). The Custom
panel shows the plan in plain words; nothing runs until the user presses Run.
Plans that reference unknown operations or presets are rejected with the
reason.

**AI rename** (`image.aiRename`, `pdf.aiRename`, `folder.aiRename` for a folder's direct image and PDF children):

- macOS 27 and later: the image (or the first PDF page rendered at 1024 px) is
  passed to the on-device model as an image attachment, together with the
  existing name and creation date.
- macOS 26: the input is text only: Vision OCR text, Vision
  `ClassifyImageRequest` labels with confidence ≥ 0.3, EXIF date and camera, and
  the existing name, truncated to about 2,000 tokens.
- The model returns a short descriptive name in the UI language (letters,
  digits, spaces, hyphens; at most 60 characters). Names are shown in the AI
  rename panel and applied only on confirmation. Collisions get numeric suffixes.

## 11. Onboarding and first launch

Shown at first launch and from Settings > General:

1. **Location check.** If the app runs from an App Translocation path (path
   contains `/AppTranslocation/`) or outside `/Applications` and
   `~/Applications`, explain how to move it to Applications and quit.
2. **Finder extension.** If the extension is not enabled, show steps and a button
   calling `FIFinderSyncController.showExtensionManagementInterface()`.
3. **Notifications.** Request authorization.
4. **Folder access.** Explain that macOS asks once per protected location
   (Desktop, Documents, Downloads, removable and network volumes) the first time
   MacEase processes a file there, with an optional shortcut to Full Disk Access.
5. **Launch at login** toggle (default on), so the menu responds instantly.

## 12. Updates

At launch and at most once every 24 hours, the host requests
`https://api.github.com/repos/TKY-27/MacEase/releases/latest`. When the tag is
newer than the running version (semantic versioning), it shows a notification
and a menu bar item linking to the release page. Nothing is downloaded or
installed automatically. Network errors are logged and ignored until the next
check.

## 13. Error handling

- Errors are typed per domain (decode, encode, commit, unsupported codec,
  permission, cancelled, target unreachable, invalid input). Each maps to a
  localized, actionable message naming the file.
- Expected per-item errors end the item as failed; the batch continues. There
  are no silent fallbacks: a fallback path (for example dav1d instead of
  VideoToolbox) is a defined behavior, not error recovery.
- Video audio conversion and extraction reject timelines requiring more than
  ten minutes of synthesized silence in total per operation. The remaining
  budget is checked before filling each gap so sparse malformed timelines
  cannot trigger unbounded output work.
- AVI indexes reject duplicate or overlapping OpenDML chunk references.
  Index reads are capped at the smaller of the file size and 128 MiB;
  records are capped at the smaller of the file size divided by the index
  entry width and 4,000,000. OpenDML references are capped at 65,536.
  These limits are checked before index allocation or record accumulation,
  and index traversal checks cancellation (ADR 0010).
- Permission errors from TCC tell the user which location needs access and link
  to the relevant System Settings pane.
- Unexpected errors are logged with `Logger` (subsystem `io.github.tky27.MacEase`)
  including the operation and file extension, never file contents.
- The extension never shows alerts. If the host cannot be launched, the menu
  shows only "Open MacEase".

## 14. Security and privacy

- URL token verification (section 3.3).
- Untrusted files are decoded in the host process. Native libraries stay at
  current versions; security updates to them trigger a patch release.
- Archive extraction uses libarchive's secure flags and never follows symlinks
  outside the destination.
- SVG rendering blocks all network loads and scripts.
- No analytics, no crash reporting service. Logs stay local.
- The menu file and history are mode 0600.

## 15. Localization

- String Catalogs for English (development language) and Japanese in the app and
  the extension.
- The host writes localized menu titles into the menu file in its own UI
  language, so the Finder menu always matches the app's language setting.
- Formats and units use the current locale; file sizes use `ByteCountFormatter`
  with decimal units.

## 16. Non-functional requirements

| Requirement | Target | Verification |
| --- | --- | --- |
| Menu build time | `menu(for:)` ≤ 30 ms for 1,000 selected items | Unit benchmark of the menu model plus manual check |
| Request transport | 5,000 paths in one request | Automated host test of URL parsing; manual end-to-end check |
| Image conversion | 12 MP HEIC to JPEG ≤ 0.5 s on M1 | `scripts/bench.sh`, manual |
| Video compression | 60 s 1080p30 H.264 15 Mbps with AAC to 20 MB ≤ 30 s on M1 | `scripts/bench.sh`, manual |
| Memory | Peak resident memory ≤ 1.5 GB for any single item except 8K video | Manual with Instruments |
| Large batches | 1,000 images processed without UI stalls; menu bar stays responsive | Manual |
| Idle | Host idle CPU ≈ 0%, resident memory ≤ 80 MB | Manual |

## 17. Testing

- `swift test` in `Packages/MacEaseKit` covers classification, menu model,
  token and URL parsing, presets, planners, commit sequences (on a temporary
  volume folder), history and undo, text conversions, and every in-house format
  with its acceptance metric.
- Fixtures are generated at test time where possible (synthetic images, tones,
  music-like signals, gradient video through AVAssetWriter). Small committed
  fixtures (under 1 MB total) cover formats that cannot be generated, such as a
  RAR archive or an AVI from a third-party encoder.
- Tests that need hardware or OS capabilities missing on CI VMs (Apple
  Intelligence, hardware encoders, HEIC encoding, Speech assets, Translation
  models) check the capability first and call `XCTSkip` (or Swift Testing
  `.enabled(if:)`) when it is missing. `make test-device` runs the full suite
  locally on a real Mac.
- Performance measurements live in `scripts/bench.sh` and are not part of CI.
- Before each release, the operator runs the manual checklist in
  `docs/spikes.md` on macOS 26 and macOS 27 (menu levels, transport, menu file
  entitlement, translocation detection, update survival of permissions).

## 18. Build, CI, signing and release

- `make bootstrap` installs XcodeGen, CMake, Meson, Ninja and pkg-config with
  Homebrew, runs `scripts/build-deps.sh`, and generates the Xcode project.
- **CI (`.github/workflows/ci.yml`)** on pushes and pull requests to `main`:
  - `lint` on `macos-26`: `swift format lint --strict --recursive`.
  - `build-26` on `macos-26` with the newest installed Xcode 26: build native
    dependencies (cached by the hash of `Vendor/deps.lock` and the build script),
    `swift test`, and `xcodebuild build` of the app in Debug.
  - `build-27` on the `xcode-27` image (generally available since
    2026-10-15) with Xcode 27: the same steps.
- **Signing.** Releases are signed with a self-signed code-signing certificate
  ("MacEase Release"), not notarized. A stable certificate keeps macOS privacy
  grants (TCC) and the Finder extension's enabled state across updates, which
  ad-hoc signatures do not. `scripts/create-signing-identity.sh` creates the
  certificate and writes the values for the repository secrets
  `MACEASE_CERT_P12_BASE64` and `MACEASE_CERT_PASSWORD` to files, never to the
  terminal; `--set-secrets` sets them with `gh`. Debug builds are
  ad-hoc signed.
- **Release (`.github/workflows/release.yml`)** on tags `v*` on the `xcode-27`
  image: build native dependencies, archive Release, sign the app and the
  extension (extension with its sandbox entitlements) with the release identity,
  build `MacEase-<version>.dmg` with an Applications symlink via
  `scripts/make-dmg.sh`, compute SHA-256, create the GitHub Release with the DMG
  and checksum, and use the matching CHANGELOG section as release notes. The
  workflow fails when the signing secrets are missing.
- Gatekeeper still blocks the first launch. README documents **Open Anyway** in
  System Settings > Privacy & Security and the alternative
  `xattr -dr com.apple.quarantine /Applications/MacEase.app`.
- Homebrew is not used. A cask failing Gatekeeper is not accepted in the
  official tap since September 2026, and a personal tap adds nothing over the
  DMG while the first launch still needs Open Anyway.

## 19. Out of scope for v1

- Intel Macs and macOS earlier than 26.
- Mac App Store, notarization, automatic update installation.
- AV1 video encoding, WMA and WMV decoding, RAR creation, DRM-protected media.
- Recursive media processing of folder contents (media operations act on
  selected files only).
- Cloud upload, sharing, accounts, telemetry, crash reporting services.
- A main document window or drag-and-drop UI.
- PDF preview (Quick Look covers it).
- Windows and Linux.

## Changelog

- 2026-10-21: Audio replacements preserve supported speaker layouts, video
  edits preserve supported alpha, and AVI index traversal rejects overlapping
  references and enforces cumulative budgets (ADR 0010).

- 2026-10-21: Output stamps are captured before commit coordination ends.
  Report saving and Analyze export choose a destination, retain colliding
  files, and record Derived outputs for undo. Timestamp arithmetic rejects
  overflow, and audio silence synthesis has a cumulative cap (ADR 0011).

- 2026-10-20: Initial specification after chat discussion, Finder Sync spikes on
  macOS 27.0.1, and an independent review.
- 2026-10-20: Same-name replace clones into staging instead of a hidden sibling
  (ADR 0007). skcms listed with libjxl. Preset schema uses `formats`, an
  `aspect` range object and `quality`, which the default table needs. The
  `xcode-27` runner image is generally available.
- 2026-10-20: In-house codec tuning recorded (ADR 0008): lightness-weighted
  lossy PNG palettes, ordered dithering as the GIF default, LZW with deferred
  clears and dictionary-aware dithering.
- 2026-10-20: MP3 encoder design and table provenance recorded (ADR 0009).
- 2026-10-21: Platform-driven adjustments recorded (ADR 0010): video target
  size steps down after a persistent miss, LINE over 300 s points to Trim,
  archive path checks replace `SECURE_NOABSOLUTEPATHS`, HEIC metadata strip
  re-encodes, MP3 below 128 kbps compresses to AAC, AI plans use menu presets,
  and the language switch asks first.
- 2026-10-21: LINE clips over 300 s open the Trim panel one second under the
  limit and compress the trimmed file (ADR 0010). Subtitles and Extract audio
  panels added; a bitrate chosen in the latter always re-encodes. The video
  Background panel offers the person and subject masks only.
- 2026-10-21: Video replace operations reject multiple video or audio tracks
  before writing so additional tracks cannot be lost (ADR 0010).
- 2026-10-21: Commit and undo stamps recorded (ADR 0011): scan checks before
  replace, bounded folder summaries, rename identity checks, safe skips for
  missing or incomplete stamps, and history retained after case-change failure.
- 2026-10-21: Undo shares commit serialization, refuses running batches and
  verifies Trash identity. Backup records save immediately, and normal quit
  waits for a sealed history flush (ADR 0011).
