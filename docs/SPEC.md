# MacEase v1 Specification

This document is the single source of truth for MacEase v1. It describes the
finished product. When code and this document disagree, this document wins;
when a decision changes, update this document, its Changelog, and add an ADR
under `docs/adr/`.

## 1. Overview

MacEase is a macOS toolkit that converts, compresses, resizes and otherwise
transforms files entirely from the Finder right-click menu. The user selects
files in Finder, opens the context menu, picks an operation, and the files are
saved as new files by default. An optional output mode replaces originals
through Trash and Undo. There is no main document window workflow.

Principles:

- **Right-click and done.** Every operation starts from the Finder context
  menu. Preset and format leaves run immediately. Custom menu entries are
  limited to Resize and Compress. Other windows collect essential input,
  confirm destructive work, or present results.
- **Never lose a file.** An original is never modified or removed until the
  output is fully written and verified. Replaced originals go to the Trash and
  every batch can be undone.
- **Local only.** All processing is on-device. No telemetry. The network is
  used only for the update check and for OS-managed model and asset downloads.
- **Native.** Apple frameworks first, permissive C libraries where Apple has no
  encoder, and in-house Swift implementations where no permissive library
  exists.

This specification defines the target finished v1, including the product
direction accepted on 2026-10-21. It is not a statement of current implementation
status. Flect is the interaction and functional reference within the explicit
scope below. Windows backend behavior is not an acceptance criterion.

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
  "schema": 2,
  "catalogVersion": "sha256 of the entries array",
  "token": "64 hex characters",
  "hostAvailable": true,
  "entries": [
    { "op": "image.resize", "preset": "percent-50", "kind": "image", "path": ["Resize", "50%"], "separatorBefore": false }
  ],
  "kinds": { "image": { "title": "Images" } }
}
```

- `entries` lists every visible menu leaf, already localized in the host's UI
  language and already filtered by settings and capabilities (hidden items,
  Apple Intelligence availability, Java availability).
- `path` gives the localized submenu titles from the kind level down to the leaf.
  Different operation IDs can share a submenu, such as Rotate and Convert.
- Schema 2 adds `separatorBefore` to each leaf. It marks a preset-group boundary
  at that leaf's parent level. After filtering, the renderer keeps group
  boundaries between surviving groups without leading, trailing, or repeated
  separators. Separators have no action or entry index. Section headers are
  not used.
- The catalog hash covers the complete ordered entries, including grouping,
  parameter values, visibility, and selection constraints. Editable menu values
  are published with their stable slot IDs and resolved parameters. Leaf
  constraints include minimum and maximum per-kind counts and applicable source
  and target formats. The host validates the parameters again before execution.
  `resizeValue` carries the resolved integer percentage or pixel edge for its
  stable resize slot; `targetBytes` carries decimal compression bytes.
- `token` is generated once from 32 random bytes on first launch, persisted by
  the host, and rotatable in Settings > Advanced.

If the menu file is missing, unreadable, or uses an unsupported schema
(including schema 1), the extension shows a single item,
"Open MacEase", which opens `macease://open`. The host shows Welcome if
onboarding is incomplete, otherwise Settings. This route never runs an operation.

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
never triggered directly by a URL; it always requires a confirmation alert.
Automatic duplicate retention can move verified redundant copies to the Trash
under the saved keep policy. It never authorizes permanent deletion.

### 3.4 Job engine

- A request becomes a **batch** of **items** (one per input file, or one item
  for multi-input operations such as PDF merge or archive creation).
- Items run concurrently up to `max(1, activeProcessorCount / 2)` for CPU-bound
  work. Hardware video encodes (VideoToolbox H.264, HEVC, HEVC with alpha) run
  one at a time. Software encodes (libvpx, libaom, ProRes on chips without a
  ProRes engine) count as CPU-bound.
- Each item reports progress in [0, 1]. Batches can be cancelled from Activity
  or the menu bar; cancellation stops running items, removes their staging files and leaves
  originals untouched.
- Each item ends as `succeeded`, `skipped(reason)` or `failed(error)`. One item
  failing never stops the rest of the batch.

### 3.5 File commit model

Each operation resolves to one commit mode before processing. Settings > General
has **When converting or editing** with two choices:

- **Save as new file** (default). Transform operations use Derived commits.
- **Replace original (move original to Trash, Undo)**. Transform operations use
  the Replace sequence below.

The default applies to new installs and existing installs without an explicit
saved output-mode choice. A saved choice is preserved. Each batch snapshots
its resolved mode and settings, so later Settings changes cannot alter a job.

**Transform** in section 8 means this switch applies. It covers image resize,
compression, conversion, rotation, flip, border trimming, background editing,
and metadata stripping; video resize, trim, compression, rotation, flip,
frame-rate changes, remove audio, and container conversion; audio conversion,
compression, normalization, and trim; PDF compression and rotation; text encoding,
line endings, and JSON formatting or sorting. AI plans use each step's policy.

Exports, extracts, and reports always keep their inputs regardless of the switch.
These include RAW/DNG conversion, image-to-PDF, icon sets, video animations,
thumbnails, extracted audio, subtitles from audio or video, video background
exports, OCR files, structural text conversion and derive-to-TXT, PDF merge,
page images, text, page extraction and split, archives, JAR decompilation,
folder trees, Analyze exports, and saved text results. Rename, Clipboard,
Report, and Trash retain their own semantics.

Resolved commit modes:

| Mode | Behavior |
| --- | --- |
| **Replace** | The output takes the original's place. The original goes to the Trash. |
| **Derived** | New files or folders are created next to the original. The original is kept. |
| **Rename** | The file is renamed. No content changes. |
| **Clipboard** | The result is copied to the pasteboard. No files change. |
| **Report** | The result is shown in a panel, optionally saved as a derived file. |
| **Trash** | Verified candidates are moved to the Trash after review or a saved duplicate keep policy. Permanent deletion always requires an alert. |

**Staging.** Outputs are written to a directory obtained from
`FileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)`,
where `destination` is the resolved output location. Staging is on that volume
and outside the user's folder (so cloud-synced
folders never see partial files). Staging is removed on success, failure and
cancel. Stale staging directories from a crash are removed at host launch.
Failed removals remain registered for later sweeps and launches; only successful
removal or confirmed absence clears a staging path. Sweeps never remove live staging.
An unreadable registry blocks new staging until it can be loaded, preserving
existing recovery records.

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
Replace, derived, rename, removal and undo check cancellation inside the
coordinated section immediately before the first mutation. Once a mutation
starts, its commit or rollback completes without another cancellation check.

**Derived names.** Outputs are created in the source's parent folder. `stem`
means the source name without its last extension, and `ext` is the retained
source extension. Conversion uses the selected target extension. Names follow
Flect's derive rules for corresponding operations:

| Operation | Candidate name before collision numbering |
| --- | --- |
| Resize, compress, rotate, trim | `stem_resized.ext`, `stem_compressed.ext`, `stem_rotated.ext`, `stem_trimmed.ext` |
| Image, video, audio, or structural text conversion; derive-to-TXT | `stem.<target>` |
| Remove metadata; image background | `stem_clean.ext`; `stem_keyed.png` for Remove or Color Key, with the resolved extension for other background edits |
| OCR; thumbnail; subtitles | `stem_ocr.txt`; `stem_thumbnail.png` or `.jpg`; `stem.srt`, `.vtt`, or `.txt` |
| Text encoding | `stem_utf8.ext`, `stem_utf8bom.ext`, `stem_utf16.ext`, `stem_sjis.ext` |
| Line endings; JSON | `stem_lf.ext`, `stem_crlf.ext`; `stem_pretty.ext`, `stem_minified.ext`, `stem_sorted.ext` |
| PDF merge | `first-ordered-stem_merged.pdf` beside the first ordered source |
| PDF page images | One page: `stem.png` or `stem.jpg`. Multiple pages: `stem_pN.png` or `.jpg`, with N padded to the total page-count width |
| PDF text; archive extraction; JAR decompilation | `stem.txt`; directory `stem`; directory `stem` |
| Folder compression | `folder-name.zip`, `.7z`, `.tar`, or `.tar.gz`, with the folder retained as the archive root |

For `.tar.gz` extraction, both suffixes are removed. Folder compression keeps
the complete folder name, so `project.v1` produces `project.v1.zip` (ADR 0025).
MacEase-only edits use explicit suffixes such as
`_flipped`, `_normalized`, `_fps30`, `_silent`, `_cropped`, and `_background`.
Video animation exports use `stem.gif`, `stem.webp`, or `stem.apng`.
Other multi-output exports use a named derived folder or the page naming rule
in section 8.6.

If any directory entry, including a dangling symbolic link, occupies a
candidate, append ` (2)`, ` (3)`,
and so on before the last extension, or after a directory name. A same-format
conversion therefore never writes back to its source in new-file mode.
Renamed Replace outputs use the same collision rule. Naming checks and the
no-replace final move run inside commit serialization and file coordination.
A concurrent collision always advances to the next suffix, even if the
colliding entry disappears. Naming traversal checks cancellation. No existence-check race
can authorize overwriting an occupied path.

Report Save and Analyze Export use a save panel to choose a folder and name.
They stage on the destination volume and verify the selected encoding and
format, then use the Derived commit path
and record an undoable batch. Existing files are never overwritten, including
after a save panel replacement confirmation. Collisions use the available-name
rule, and the host tells the user the final name when it changed.

**Preservation.** These rules apply to both output modes unless explicitly limited.

- Creation date, modification date, Finder tags and Finder comment are copied
  to the output.
- EXIF, XMP, IPTC and the ICC profile are copied when the output format can hold
  them. Unsupported metadata must never disappear silently. Replace refuses a
  target that cannot preserve it. Derived conversions report each unsupported
  metadata class as a visible warning while retaining the source. Explicit
  metadata stripping and the documented platform GPS policy are exceptions.
  Image checks name only present EXIF, XMP and IPTC classes, ignoring empty
  values and generated raster dimensions and color-space tags. New-file
  conversion to formats such as BMP, TGA and ICO warns; Replace refuses before
  staging and suggests Save as New File.
- Pixel rotation sets EXIF Orientation to 1.
- ISO 21496-1 and Apple HDR gain maps are kept for HEIC and JPEG outputs
  through ImageIO auxiliary data, including their calibration metadata.
  Geometry edits transform the map at its own resolution. Encoding verifies
  map dimensions, pixel samples and calibration values before replacement,
  including nested ISO channel metadata. Core Image decodes ISO RGB maps
  whose ImageIO payload exposes planar YCbCr without raster bytes; color
  management is disabled and ImageIO writes packed RGB auxiliary samples.
  Explicit auxiliary orientation takes precedence over the base orientation,
  and pixel transforms normalize both to upright (see
  `adr/0012-gain-map-calibration-and-raster-decoding.md`).
  Unreadable or unsupported maps fail with a typed error. Background changes
  and added canvas pixels, including non-right-angle rotations and letterbox
  presets, refuse HDR replacement until neutral gain can be derived reliably.
  When the resolved image output cannot preserve HDR, Save as New File uses
  the same high-quality tone mapping as Convert > SDR and reports a visible
  warning. Replace refuses before writing, explaining the HDR loss and
  suggesting Save as New File or Convert > SDR. This also covers operations
  whose geometry cannot preserve gain maps. Flattening an alpha-bearing HDR
  base also tone-maps first, before compositing onto the configured background.
  Unsupported map decoding still
  fails safely. See ADR 0010 for bounded raster support and ADR 0019 for the
  output-mode policy.
- Image outputs that cannot retain actually used transparency are flattened
  onto the configured Images custom background color (white by default) only
  when the resolved mode retains the original, with a visible warning.
  Replace refuses before writing and suggests Save as New File. Fully opaque
  alpha channels do not trigger refusal or a warning.
- Platform presets remove GPS data by default (setting).

**Deletions.** Duplicate and empty-folder removal move items to the Trash by
default. Permanent deletion is an opt-in setting and always asks for
confirmation in an alert.

### 3.6 History and undo

- History keeps the last 100 batches in
  `~/Library/Application Support/MacEase/history.json`, with recent appends in
  the adjacent `history.journal`. Existing version-1 snapshots remain readable
  without migration steps. Both files have owner-only permissions.
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
- Replace and removal records append newline-delimited JSON deltas with
  increasing sequence numbers. The journal and its containing directory are
  synchronized before the commit gate is released. Each delta holds only the
  newly committed entries and their batch metadata, so a batch writes bytes
  proportional to its records instead of repeatedly rewriting growing history.
  Other records may be coalesced for up to one second and are flushed at batch
  completion. Failed appends remain pending for retry. A persistence failure
  blocks later file commits, including Derived, until a pre-commit retry
  synchronizes the pending history. Failed retries return a typed history
  error before replacing, renaming, trashing, deleting, or creating outputs.
  Multi-file operations record each mutation before attempting the next file.
  The throttle permits delayed writes, not bypassing a known persistence failure.
- Batch completion, launch recovery and orderly quit compact history. A staged
  snapshot containing the applied sequence is synchronized, atomically renamed
  over `history.json`, and its directory synchronized before resetting and
  synchronizing the journal. Replay ignores already checkpointed sequences,
  applies later sequences exactly once, and ignores only an unterminated final
  record. That torn suffix is removed before further appends. Complete malformed
  records or missing sequences block further mutations without discarding the
  recovery files. Compaction stays synchronous on the history actor; undo and
  commits retain their shared gate. Failed snapshot writes remain retryable,
  and undo or clear changes must reach a snapshot before later durable appends.
  These guarantees cover application crashes and forced termination, not
  hardware power loss. See ADR 0020.
- Normal application termination stops new requests, snapshots and cancels pending
  jobs, and waits asynchronously up to five seconds for their cleanup. A timeout
  is logged; remaining staging stays registered for launch recovery. Accepted
  undo requests still finish without this timeout. An engine termination barrier
  then waits for the current commit and its record, seals further commits and undo, and
  flushes history. AppKit defers termination until this completes off the main
  actor. A flush failure cancels termination and allows a retry. Forced process
  termination and crashes cannot provide this orderly shutdown guarantee.
- The completion notification offers **Undo** and **Show in Finder**. The menu
  bar shows the last 10 batches with Undo.
- A batch produces at most one notification under section 6, whatever its size.
- New-file transforms use Derived history records, including the actual final
  path and commit-time stamp. Undo removes the created output by moving it to
  the Trash and leaves the source untouched. Staging, verification, history
  flush, cancellation, and stamp checks are never bypassed for new-file mode.

### 3.7 Native dependencies

All are permissively licensed and compatible with MIT distribution. Versions are
the latest stable release at implementation time, pinned by version, source URL
and SHA-256 in `Vendor/deps.lock`. `scripts/build-deps.sh` downloads, verifies,
builds arm64 static libraries with deployment target 26.0 and packages them as
xcframeworks into `Vendor/build/` (ignored by git, cached in CI).
`Package.swift` fails with a message pointing to the script when they are missing.
The exception is toml++ 3.4.0, whose single header is committed in the
`TOMLBridge` target and compiled by SwiftPM as C++17. Its exact source URL and
SHA-256 are pinned in `Vendor/deps.lock`; it needs no download or xcframework.

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
| toml++ 3.4.0 | MIT | TOML parsing and emitting | Vendored single header, C++17 behind an owned C bridge |

Swift packages are pinned with `exact:` in `Packages/MacEaseKit/Package.swift`
and recorded in the committed `Package.resolved`. Their license texts, checked
against the pinned checkouts, live in `Vendor/licenses/`.

| Package | Version | License | Purpose |
| --- | --- | --- | --- |
| swift-cmark (cmark-gfm 0.29.0.gfm.13) | 0.9.0 | BSD-2-Clause, with MIT-licensed parts | CommonMark and GFM Markdown to HTML |
| Yams (bundles libyaml at `acd6f6f`) | 6.2.2 | MIT (Yams and libyaml) | YAML parsing and emitting |

`scripts/generate-notices.sh` builds `THIRD_PARTY_NOTICES.txt` from
`Vendor/deps.lock`, the license and patent files of each source, and the Swift
package licenses. It fails when `Package.resolved` disagrees with the versions
it lists or when the vendored toml++ header differs from its pinned SHA-256.
The toml++ MIT license is stored in `Vendor/licenses/tomlplusplus/`.
An optional output path permits validation without rewriting build artifacts.
The app shows the generated notices in Settings > About.

**Source policy.** GPL, LGPL, and AGPL sources, including FFmpeg, LAME, gifski,
pngquant, libimagequant, and Clop, may be read to study architecture and
algorithms. Their code must never be copied, translated, adapted, or incorporated
into MacEase. Implement independently using platform APIs, specifications, and
papers. This supersedes ADR 0004's prohibition on reading those sources.

Flect is Apache-2.0 and is the interaction reference. Its developer's permission
to study or reuse it does not replace license terms. MacEase independently
implements the design in Swift and reuses only facts and data, such as extension
lists, menu taxonomy, and preset values. No Flect code or assets are reused.
If code is ever copied, retain the Apache-2.0 license and applicable notices,
mark modifications, and include NOTICE and attribution in
`THIRD_PARTY_NOTICES.txt` as required by the license and project policy.
See `adr/0013-flect-style-menu-first-direction.md`.

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

### 4.1 Scope and selection

- `directoryURLs` is `/`, covering mounted volumes. Local folders are verified;
  external and network volumes require release checks.
- Item menus use `contextualMenuForItems`. Folder-background menus use
  `contextualMenuForContainer` and the targeted folder's operations.
- `menu(for:)` returns within 30 ms for 1,000 selected items. Classification and
  pruning use filenames, extensions, and per-kind counts only. The extension
  never reads selection contents, sizes, HDR metadata, or animation frames.
  The host checks real content types and skips mismatches with a reason.
- Size-aware compression pruning, Finder icon progress, and nested SF Symbols
  require successful platform spikes before adoption. Until then, size presets
  remain visible and the host reports files already below the target. No
  synchronous GIF probing or persistent progress badges are used.

### 4.2 Structure and pruning

One top-level **MacEase ▸** uses `wand.and.sparkles`. A single kind exposes
operations directly, with choices one level below. Mixed selections retain
`MacEase ▸ Kind (n) ▸ Operation ▸ Choice`, at most four levels. Counts and
single-selection limits use that kind's subset. Unknown files and packages
receive All Files operations. Folder selection never enables recursive media
operations.

Only image/video Resize and image/video/audio Compress have **Custom Size…**.
Flip leaves share Rotate. Video animation leaves share Convert. JSON commands
are flat operation-level leaves. Separators divide preset groups under schema 2.
There are no category headers inside homogeneous menus, redundant option forms,
or fifth-level submenus. Format leaves use plain names such as **PNG**.
Ellipses indicate input, review, or confirmation, not immediate processing.

Selection rules:

- Canonical aliases include jpg/jpeg/jpe, tif/tiff, heic/heif/hif, aif/aiff,
  and ogg/oga. A conversion target is hidden only when it is a no-op for every
  selected file of that kind. A mixed-format selection can still normalize to
  one format. Audio M4A AAC and ALAC leaves are never pruned by extension,
  because the codec is unknown without reading the file.
- Text structural conversion requires one canonical source format and offers
  only its valid targets. Generic text formats can still derive TXT. JSON
  Pretty Print, Minify, and Sort Keys appear only when all Text inputs are JSON.
- Trim for video or audio, Choose Frame, Extract Pages, and Copy as Base64
  require exactly one input of that kind. PDF Merge requires two or more PDFs.
  Make PDF supports one image directly and opens page ordering for two or more.
- Analyze combines all selected folder roots in one report. It has no
  single-folder limit. Repeated and overlapping roots are counted once.
- Hidden operations and individual leaves are removed before serialization.
  Empty submenus and redundant separators disappear after selection pruning.
  The host validates count, type, capability, and parameters again on invocation.
- Apple Intelligence items require availability and the saved AI toggle. JAR
  Decompile requires a Java runtime found with `/usr/libexec/java_home`.

### 4.3 Classification

| Kind | Extensions |
| --- | --- |
| image | jpg, jpeg, jpe, png, apng, heic, heif, hif, avif, jxl, webp, gif, tif, tiff, bmp, tga, psd, ico, icns, svg, dng, cr2, cr3, nef, arw, raf, orf, rw2 |
| video | mp4, m4v, mov, mkv, webm, avi, flv |
| audio | mp3, m4a, aac, wav, aif, aiff, aifc, flac, ogg, oga, opus, caf |
| pdf | pdf |
| document | docx, odt, rtf, rtfd (including directory packages) |
| plist | plist (binary or XML) |
| text | txt, text, md, markdown, log, csv, tsv, ini, cfg, conf, json, xml, yaml, yml, toml, html, htm, css, js, mjs, cjs, ts, tsx, jsx, c, h, cpp, hpp, cc, hh, cs, java, kt, py, rb, go, rs, php, pl, lua, sh, bash, bat, cmd, ps1, psm1, sql, srt, vtt, asc, tex, rst, env, props, properties, gradle, cmake, m, mm, swift, vb, r, jl |
| archive | zip, 7z, tar, gz, tgz, bz2, xz, rar, including compound tar.gz names |
| jar | jar |
| folder | Directories. Packages such as `.app` are files with only All Files operations. |

M4A remains Audio. Flect's classification of M4A as Video is not adopted.
Scripts and source files are decoded as text and never executed.

### 4.4 Menu groups and defaults

The first table gives operation order. Semicolons delimit entries there; only
the word `separator` inserts a menu separator. In the second table, semicolons
divide preset groups and render as separators. `hidden` means hidden only on
new installs. Single leaves and count constraints follow section 4.2. All Files
Checksum follows a separator in single-kind file menus, or an **All Files (n)** submenu in mixed
menus.

| Kind | Operation order and grouped choices |
| --- | --- |
| Images | Resize; Compress; Convert; Rotate; Background; Remove Metadata; Recognize Text; separator; Make PDF; Make Icon; Trim Borders; Copy as Base64 (hidden); separator; Rename with Apple Intelligence…; Ask Apple Intelligence… |
| Videos | Resize; Trim…; Thumbnail; Subtitles; Compress; Rotate; Convert; Extract Audio; Frame Rate; Remove Audio; Background; separator; Ask Apple Intelligence… |
| Audio | Convert; Subtitles; Compress; Normalize Loudness; Trim…; separator; Ask Apple Intelligence… |
| PDFs | Merge…; Export as Images; Export as Text; Compress; Rotate; Extract Pages…; Split into Pages; separator; Rename with Apple Intelligence… |
| Documents / Property Lists | Convert |
| Text | Convert; Encoding; Line Endings; separator when JSON commands survive; Pretty Print; Minify; Sort Keys |
| Folders | Compress; Rename…; Folder Tree; Analyze…; separator; Remove Duplicates… or Remove Duplicates under an automatic keep policy; Remove Empty Folders…; separator; Rename Contents with Apple Intelligence… |
| Archives / JAR | Extract / Decompile |

| Submenu | Groups in display order |
| --- | --- |
| Image Resize | 75%, 50%, 25%; Long Edge 3840 px (hidden), 2560 px (hidden), 1920 px, 1080 px; Custom Size… |
| Image Compress | Discord (20 MB), X (5 MB), Instagram (8 MB), Email (18 MB), Web; High Quality, Medium Quality, Low Quality; Custom Size… |
| Image Convert | PNG, JPEG, HEIC, WebP, AVIF, JPEG XL; GIF, TIFF, BMP (hidden), TGA; ICO (hidden), ICNS (hidden), SVG, PDF; SDR when applicable (section 8.12) |
| Image and video Rotate | 90° Right, 90° Left, 180°, 45° (hidden, editable extra-angle slot); Flip Horizontal, Flip Vertical |
| Background | Remove, Green Screen, Blue Screen, Custom Color, Blur; Color Key for images only |
| Remove Metadata / Recognize Text | All, Location Only, Selected Fields / Copy Text, Save as .txt, Show |
| Make Icon | macOS Icon (.icns), iOS AppIcon Set, Windows Icon (.ico) |
| Video Resize | 50%; 2160p (4K) (hidden), 1080p, 720p, 480p; Custom Size… |
| Video Thumbnail | First Frame, Middle Frame; Choose Frame… |
| Audio and video Subtitles | SRT, WebVTT, Plain Text; Translated SRT |
| Video Compress | Discord (20 MB), X, Instagram Reels, LINE, Email (18 MB); 10 MB, 25 MB, 50 MB, 100 MB (hidden); High Quality, Medium Quality, Low Quality; Custom Size… |
| Video Convert | MP4, MOV, M4V (hidden), MKV, WebM, AVI (hidden), FLV (hidden); GIF, GIF for X (15 MB), Animated WebP, APNG (hidden); SDR when applicable |
| Extract Audio | M4A (AAC), M4A (ALAC), MP3, AAC, WAV, AIFF (hidden), FLAC, OGG (Vorbis) (hidden), Opus (hidden) |
| Audio Convert | MP3, M4A (AAC), M4A (ALAC), AAC, WAV, AIFF, FLAC, OGG (Vorbis), Opus, CAF (PCM), CAF (ALAC) |
| Audio Compress | 192 kbps, 128 kbps, 96 kbps, 64 kbps; Custom Size… |
| Normalize Loudness / Frame Rate | −14 LUFS, −16 LUFS, −23 LUFS / 24 fps, 30 fps, 60 fps |
| Encoding / Line Endings | UTF-8, UTF-8 with BOM, UTF-16, Shift_JIS / LF (macOS, Linux), CRLF (Windows) |
| Folder Compress / Folder Tree | ZIP, 7z, TAR, tar.gz / Copy, Save as .txt, Save as .md |
| Checksum | SHA-256, MD5, SHA-1 (hidden), SHA-512 (hidden) |

Platform size labels are generated from saved preset limits, never hardcoded
beside editable values. General percentage, pixel, angle, and byte-target slots
are editable in Finder Menu. Text conversion pairs are specified in section 8.13.

## 5. Panels

Windows appear only for essential per-run input, destructive review, and results.
They use native title bars, system controls, grouped forms, and system colors.
Flect supplies interaction structure. Finder copy windows and macOS Settings
supply layout conventions. Decorative cards, gradients, custom glass content,
and repeated explanatory labels are excluded, consistent with the
[Impeccable slop catalog](https://impeccable.style/slop/) and
[Apple menu guidance](https://developer.apple.com/design/human-interface-guidelines/menus).

Input panels center on the active screen, accept Return for the action and Esc
for Cancel, and focus the first field. They validate inline and disable invalid
actions. Forms are about 420 pt wide, media panels 600 pt, with content-driven
heights that support larger text. Keyboard and VoiceOver provide alternatives
to dragging. Reduce Motion, Reduce Transparency, and Increase Contrast use
system behavior. Values are remembered only for retained panels.

| Panel | Used by | Contents |
| --- | --- | --- |
| Size | Image/video Resize > Custom Size… | Width and Height in pixels, live result for the first file. One blank dimension preserves proportions; both fit inside the box. Images have Allow enlarging. No mode picker. |
| Target size | Image/video/audio Compress > Custom Size… | One decimal size field, largest-selected-file hint, live byte equivalent. No quality/platform picker or processing toggles. |
| Trim | Single video or audio trim; single over-limit LINE clip | AVPlayerView for native containers/audio; thumbnail strip sampled at one twentieth of duration and numeric times for other supported video containers. Start/end, kept duration, keyframe/exact choice defaulted from Settings. |
| Frame picker | Single video Choose Frame… | Preview and timestamp. |
| Page order | PDF Merge, Make PDF with multiple images | Thumbnails, reorder/remove, Move Up and Move Down. |
| Page select | Single PDF Extract Pages… | Page ranges and thumbnails. |
| Rename / AI rename | Rename requests | Prefix, suffix, find/replace, numbering (start, step, digits), creation/EXIF date, live preview table; AI suggestions remain editable and require confirmation. |
| Duplicates | Ask every time, the default keep policy | Opens after the scan finishes in Activity. Verified groups with keep-one choices, oldest/newest proposals, reclaimable bytes, Move to Trash. Permanent deletion requires an additional alert. |
| Analyze | Selected folder roots | Opens after the scan finishes in Activity. One combined report, named roots, totals, largest 50 files, size by type, duplicate and empty summaries, and Export… with a format pop-up (CSV, JSON, HTML, Plain Text, Markdown) that starts at the Settings default. |
| Text result | OCR Show, multi-file checksum, report details | Read-only text, Copy and Save. |
| Password / Encoding | Engine requests | Secure archive password field remembered only for the batch, or ambiguous source text encoding. |
| Ask Apple Intelligence | Natural-language requests | Prompt, validated plan, explicit Run. |
| Panel failure | Failed panel preparation | Actionable failure and retry or close. |

Angle, Animation, Background, Subtitles, Extract Audio, and generic Options
panels are removed. Their values move to Settings as listed in section 7.
The Empty Folders checklist is replaced by a confirmation alert after scanning
in Activity. It lists at most 12 paths and the remaining count, with Move to
Trash and Cancel. Permanent deletion uses Delete Permanently and defaults to
Cancel. No excluded or unreadable descendant can make a parent deletable.

## 6. Progress and feedback

One shared **Activity** window shows all running batches. It is enabled by
default and appears only if a batch is still running after 0.8 seconds. It is a
nonactivating, closable NSPanel at normal level, about 420 pt wide, with an
autosaved frame on the active space. It never takes focus from Finder. Scans
for duplicates, empty folders, and Analyze use the same window.

Each batch row shows operation and count, current filename, completed/total,
a determinate progress bar or indeterminate scan, and a separately labelled
Stop button. Rows use spacing rather than cards. Status is **Done.**,
**Finished with {n} problems.**, **Finished — {n} skipped.**,
**Finished with {n} problems, {m} skipped.**, **Cancelled.**, or **Failed.**
Skipped items are not problems. Problems and skips expand inline with
filenames and actionable reasons. Only failures use the error color.
Scan rows read **Scanning {folders}…** with an indeterminate bar until the
scan reports progress; Stop cancels the scan and opens nothing. Finished rows offer Show in Finder and Undo when applicable. VoiceOver
reads progress and announces completion.

General settings default to close after success on, after cancel on, after
failure off. Success with warnings or skips stays visible. The window closes
when no rows remain. Closing Activity hides it without cancelling jobs. Stop
cancels the chosen batch. Turning Show progress window off keeps menu-bar and
notification feedback.

The menu bar keeps active batches, Cancel, Results, and the last 10 batches
with Undo and Show in Finder. **Show Progress** appears while jobs run. The
busy symbol alternates only when Reduce Motion is off.

`UserNotifications` sends at most one completion banner per batch, with counts,
the first problem, Undo, and Show in Finder. A completed row retained and visible
in Activity suppresses its duplicate banner. Successful rows that auto-close
still produce the banner. Failure-only batches notify when Activity is disabled
or was closed by the user. Notification denial leaves results in Activity and
the menu bar. Stale-menu and permission notifications remain actionable.

Invalid inputs become per-item skipped or failed results while valid items
continue. Per-file problems never open modal alerts. Panels validate inline.
Alerts remain for blocking app states, failed history flush on quit,
Remove Empty confirmation, and permanent-delete confirmation.

## 7. Settings

Settings uses a resizable `NavigationSplitView` sidebar and grouped detail forms,
with a minimum size of 720 × 520 pt. Changes apply immediately and persist in
host `UserDefaults`, except preset overrides in section 9. There are no Apply
or OK buttons. Language changes ask before relaunch because active jobs stop.

| Page | Settings and defaults |
| --- | --- |
| General | Language (System, English, Japanese), launch at login (on), notifications, When converting or editing: Save as new file (default) / Replace original (move original to Trash, Undo), Show progress window (on), close after success (on), cancel (on), failure (off), Allow permanent delete (off), Show Welcome Window… |
| Finder Menu | Tri-state Kind > Operation > Preset visibility, Show All / Hide All, capability notes, editable percentage/pixel/angle/byte-target slots with explicit units and reset, extra-angle visibility and degrees (45°), platform preset editor moved here from Presets. |
| Images | Per-format quality, PNG optimization, GIF dithering, metadata fields (EXIF, GPS, maker notes, comments, XMP, IPTC), platform GPS policy, Subject/Person mask (Subject default), green (#00B140), blue (#0047BB), custom background color and blur radius, color-key color and tolerance, rotation fill (transparent when possible or chosen color), SVG mode (Trace or Embedded PNG) and tracing colors (1–8). |
| Video | Re-encode codec (Auto, H.264, HEVC), speed/quality, downscale and fps reduction, trim accuracy, rotation fill, editable frame-rate values, animated-image width/fps/colors/dithering/loop/range defaults for GIF/WebP/APNG, thumbnail format/quality/maximum width, background mask (Person default), transparent-video format. |
| Audio | Per-format bitrate, MP3 CBR/VBR, loudness defaults and editable loudness menu values, extracted-audio bitrate (Automatic copies when possible, explicit rates re-encode), extract default format for AI plans only. |
| Folders | Verified duplicate matching, minimum bytes (0), ignore empty files (on), optional name/time match (off), ignore hidden files, copy to keep (Ask every time default, Keep oldest, Keep newest), excluded folder names plus an Exclusion Rules sheet for folder, file, and extension patterns per scope (all folder scans, Remove Duplicates, Remove Empty Folders, Folder Tree, Analyze, Rename), folders-only Tree (off), empty-folder definition, rename defaults, archive defaults including exclusion of `.DS_Store`, `__MACOSX`, and AppleDouble files from new archives, Analyze default export format (CSV). |
| Text | Shift_JIS policy (fail default, ?, numeric references, or validated custom substitute), JSON indent (2, 4, tab), comparison (ordinal default, case-insensitive, natural), ascending/descending (ascending), recursive/root-only (recursive), pinned keys (empty), primitive-array sorting (off), CSV type inference (off). PDF section: page image resolution (144 dpi), layout (pages folder default, loose files optional). |
| Text Recognition & AI | OCR languages and output default (clipboard), OCR file encoding (UTF-8 default, UTF-8 BOM, UTF-16 LE BOM, Shift_JIS), spoken language, subtitle format and translation target, AI on/off. Audio and video share subtitle settings. |
| Advanced | Concurrency, token rotation, clear history, logs, diagnostics, Full Disk Access, Reset All Settings… with confirmation. Reset preserves history and preset overrides unless explicitly selected. |
| About | Version, links, MIT license, third-party notices. |

Rarely changed options sit one click deeper: duplicate matching filters
behind **Matching**, pinned keys and primitive-array sorting behind **More
Sort Options**. Numeric menu values keep invalid text visible beside an inline
message and never save it.

Per-preset visibility uses stable operation/preset IDs and preserves hidden
operation choices during migration. Default-hidden leaves in section 4.4 apply
only to new installs. Existing installs retain their menu visibility, including
when they never customized it. New visibility defaults never overwrite a user's
choices. Unsupported capabilities remain unavailable regardless of visibility.
Saved changes rewrite menu schema 2 and its catalog hash.

No removed panel retains an exclusive value. Image/video fill, masks, background
colors and format, animation options, subtitle languages, extracted-audio bitrate,
convert quality, SVG colors, PDF dpi/layout, custom frame rate, custom loudness,
and metadata fields are reachable in their Settings pages and used by planners.
The arbitrary-angle dial is replaced by one editable extra-angle leaf.

## 8. Operations

Columns: **ID** is the stable operation identifier. **Mode** is the commit mode
from section 3.5. Transform resolves through the output-mode switch. Presets
are menu leaves with groups and visibility from section 4. Only Resize and
Compress offer Custom Size…. Essential input windows are listed in section 5.

### 8.1 Images

Inputs: everything ImageIO decodes (including HEIC, AVIF, JXL, WebP, RAW and
DNG), plus SVG rendered by WKWebView with a content rule list that blocks every
network load, plus ICO and ICNS via the in-house readers when ImageIO fails.

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `image.resize` | 25%, 50%, 75%, long edge 1080, 1920, 2560, 3840 | Transform | Lanczos via Core Image; keeps format, metadata and every animation frame; never upscales unless Allow enlarging is enabled in the Size panel or saved resize settings |
| `image.compress` | Discord, X, Instagram, Email, Web, High, Medium, Low quality | Transform | Size targets per section 8.10; quality presets map to per-format quality values; PNG uses lossy quantization; keeps format unless the preset requires another (Instagram requires JPEG) |
| `image.convert` | PNG, JPEG, HEIC, WebP, AVIF, JPEG XL, GIF, TIFF, BMP, TGA, ICO, ICNS, SVG, PDF | Transform (always Derived for RAW/DNG/PSD inputs and PDF output) | Animated inputs retain all frames and timing in GIF, APNG, or animated WebP; incompatible targets fail before writing. Multi-page TIFF to PDF keeps all pages; other targets must preserve all pages or fail; SVG uses Trace or Embedded PNG per Settings; embedded output retains raster appearance and never claims vector tracing |
| `image.rotate` | 90° right, 90° left, 180°, extra angle from Settings | Transform | Multiples of 90° on JPEG without gain maps change only the orientation tag (lossless); HDR JPEG rotates base and gain-map pixels together; other angles rotate pixels with transparent corners, or the fill color when the format has no alpha, subject to the HDR preservation guard in section 3.5 |
| `image.flip` | Horizontal, Vertical | Transform | Pixel flip, orientation reset to 1 |
| `image.trimBorders` | — | Transform | Removes uniform borders matching the corner color within tolerance |
| `image.background` | Remove, Green Screen, Blue Screen, Custom Color, Blur, Color Key | Transform | Subject mask from Vision `GenerateForegroundInstanceMaskRequest` (all instances), person mask option, or color key with tolerance; mask edges feathered 1 px; Remove outputs alpha and converts to PNG when the source format has no alpha (JPEG, BMP) |
| `image.stripMetadata` | All, Location Only, Selected Fields | Transform | Pixels untouched for JPEG (`CGImageDestinationCopyImageSource`), PNG and TIFF (stored pixels with new metadata); HEIC re-encodes at the settings quality because macOS keeps its metadata otherwise (ADR 0010) |
| `image.ocr` | Copy text, Save as .txt, Show | Clipboard, Derived, Report | Vision `RecognizeTextRequest` accurate, language correction on, languages from settings with automatic detection |
| `image.toPDF` | — | Derived | One PDF from all selected images, initially in natural filename order; Page order panel when more than one image |
| `image.iconSet` | macOS icon (.icns), iOS AppIcon set, Windows icon (.ico) | Derived | Non-square inputs are padded to square with transparency; AppIcon set writes `Contents.json` and the sizes Xcode 26 expects |
| `image.copyBase64` | — | Clipboard | `data:` URI with the correct MIME type; refuses files over 10 MB |
| `image.aiRename` | — | Rename | Section 10 |
| `image.aiCustom` | — | Depends on plan | Section 10 |

Image property-loss checks apply to conversion, compression and platform
presets, geometry, background edits, metadata re-encoding, and icon/PDF exports.
They inspect actual alpha samples and HDR signals in every frame or page.
Always-Derived exports, including PSD, RAW, icons and PDF, keep that mode even
when Replace is selected. PDF retains alpha directly. JPEG and BMP flatten
using the configured custom background color, with the section 3.5 warning.
GIF and traced SVG retain binary alpha only. Partial alpha follows the same
flattening policy; embedded-PNG SVG retains full alpha.

TIFF metadata stripping reads, filters, and writes each page's own metadata
with its stored pixels. It skips only when no page has a selected field to
remove. Multipage rewrites retain the cumulative image allocation budget.
Ordinary TIFF flip, rotation, resize and TIFF encoding also retain each page's
own metadata on the corresponding output page, with orientation reset after
pixel transforms.

### 8.2 Videos

Containers: MP4, M4V, MOV through AVFoundation; MKV, WebM, AVI, FLV through
the in-house demuxers. Video codecs: H.264, HEVC, ProRes, MPEG-4 Part 2 and
MJPEG through VideoToolbox; VP8 and VP9 through libvpx; AV1 through VideoToolbox
when `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)` is true, otherwise
dav1d. Audio codecs: AAC, MP3, PCM, ALAC, AC-3 through AudioToolbox; Opus and
Vorbis through libopus and libvorbis; FLAC through AudioToolbox. Unsupported
codecs (DTS, WMA, WMV, Sorenson H.263, VP6, Screen Video, RealVideo) fail with
a message naming the codec.

Transform operations in either output mode refuse inputs with more than one
video track or more than one audio track before writing an output, because the
pipeline selects the first track of each kind. Explicit exports such as
thumbnails, animation, and audio extraction select the required tracks and
report omitted streams. A new-file Transform is not permission to drop streams.
Transforms also refuse streams the pipeline cannot preserve, including
subtitles, attachments, chapters and data or timecode tracks. The input exposes
these skipped streams so they cannot disappear silently. Removing audio only
permits the requested audio omission. Explicit Derived exports report other
stream omissions while keeping the original. No frame, stream, metadata, alpha,
or channel loss is silent.

Resize, rotation, flip, frame-rate changes, exact trim, conversion and every
compression attempt preserve input alpha through HEVC with alpha or ProRes
4444 in MOV, and VP9 with alpha in WebM. Generic compression selects MOV or
WebM for transparent sources. Explicit codec/container constraints remain
binding. When they cannot carry alpha, Save as New File composites onto the
configured video rotation background and reports `videoTransparencyFlattened`.
Replace refuses before staging. Stream-copy edits retain existing alpha only
when the destination can carry it (ADR 0026).
Arbitrary-angle rotation keeps source transparency and leaves added canvas
transparent when the selected encoder preserves alpha.

Ordinary re-encodes preserve supported BT.2020 PQ/HLG through 10-bit HEVC
Main10, including transfer, primaries, matrix, mastering-display and
content-light metadata. Decode and geometry processing retain HDR precision.
HLG does not require mastering-display or content-light metadata. HLG encoding
disables VideoToolbox's automatic Dolby Vision generation; PQ retains its
static HDR metadata. Encoded outputs are reopened before commit to verify
these HDR properties; writer omissions fail without replacing the source.
Dolby Vision 8.4 sources use their HLG-compatible base layer. Ordinary edits
and compression in Save as New File encode HEVC Main10 when supported and
report `dolbyVisionRemoved`. Copy-based edits re-encode the base layer so
the output does not retain stale dynamic metadata. Replace refuses before
staging because these operations cannot preserve Dolby Vision metadata.
Verification compares the base-layer HLG configuration without requiring a
Dolby Vision record in the output. Other Dolby Vision profiles, mixed Dolby
Vision and non-Dolby Vision formats, and unsupported dynamic metadata refuse.
Targets requiring SDR, including H.264, animation and thumbnail exports, share the
Convert > SDR decoding path and report `videoToneMappedToSDR` in new-file
mode. Replace refuses before staging. Always-Derived exports keep their
resolved mode. Dolby Vision 8.4 SDR targets also report `dolbyVisionRemoved`.
Unsupported HDR decoding, dynamic metadata or incompatible source formats
refuse rather than silently lose HDR. BT.709 tags describe only SDR output.
Matroska/WebM Colour transfer and static HDR fields are detected before
decoding. Container-side HDR metadata currently refuses remuxing and editing
because these fields cannot yet be carried or tone-mapped safely by that
backend. HEVC HDR signalled entirely in parameter sets uses Main10 preservation.

Native MOV, MP4 and M4V remuxes and edits carry asset and track metadata,
language, preferred volume, enabled state and representable alternate track
groups. A destination that cannot store a present property reports its typed
metadata-loss warning in new-file mode and refuses before staging in Replace.
The refusal follows the resolved result mode. Audio extraction, animation, thumbnail and
background exports warn even when General settings selects Replace.
Container conversion remains a Transform and follows that setting.
Singleton alternate groups and encoder/software tags are not user-property
loss. Titles, descriptions, locations, creation dates, authorship and other
user metadata remain protected.
Matroska/WebM Info Title and Tags SimpleTag entries count as user metadata;
track-targeted tags and TrackEntry Name count as track metadata.
TrackEntry LanguageBCP47 takes precedence over legacy Language regardless of
element order. Unsupported track names and languages use the same loss checks.
Their loss warns for new files
and always-Derived exports, and refuses Replace before staging. MuxingApp and
WritingApp identify provenance and do not count as user metadata.
Alternate groups requiring omitted tracks are not reconstructed partially.
MOV retains QuickTime ISO6709 locations exactly. MP4/M4V location conversion
can add an absent altitude; this is disclosed property loss, with coordinates
retained in new-file mode and refusal before staging in Replace. Native outputs
are also compared with source properties before commit to catch unexpected
writer omissions or normalization.
Explicit Convert > SDR uses the same metadata preflight and output comparison;
permission to remove HDR does not permit other property loss.
These rules extend ADR 0019's property-loss policy to video (ADR 0026).

Matroska/WebM display dimensions, display units and pixel cropping, and native
clean aperture and pixel aspect ratio, are read separately from coded
dimensions. Matroska/WebM copies retain the original container fields and map
representable native geometry to display dimensions and pixel cropping.
Native MOV/MP4/M4V copies retain representable clean aperture and pixel aspect
ratio. Re-encoding and image exports crop first, then apply the display aspect
before rotation, reflection or resizing. Pixel units retain the declared
display size; physical units and aspect-ratio units use the cropped height
with the declared ratio. Unknown units and geometry a destination cannot
represent use the existing track-metadata warning for new-file/Derived work
and refusal before staging for Replace. Copied output geometry is verified
before commit.

Lossless audio extraction retains the source ALAC/FLAC precision when
re-encoding. Unknown or unrepresentable precision refuses before staging.
PCM copies retain integer samples exactly, apply source trim/edit timing,
and fill initial delays and timestamp gaps with silence at the source depth.
PCM copies and audio re-encodes share timestamp continuity handling. Within a
container timestamp quantum plus sample rounding, consecutive PCM packets
advance by their sample counts instead of rounded container times.
They share the cumulative synthesized-silence limit in section 13.

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `video.resize` | 50%, 2160p, 1080p, 720p, 480p | Transform | Re-encodes video with the source codec family when it is H.264 or HEVC, otherwise the settings codec; audio is copied |
| `video.trim` | — (panel) | Transform | Keyframe mode copies streams and starts at the keyframe at or before the mark; exact mode re-encodes |
| `video.compress` | Discord, X, Instagram Reels, LINE, Email, 10 MB, 25 MB, 50 MB, 100 MB, High, Medium, Low quality | Transform | Section 8.10; bundled platform presets default to MP4 with H.264 High and AAC; edited presets honor section 9; generic presets use HEVC (`hvc1`) in the source container when it supports HEVC, else MP4 |
| `video.rotate` | 90° right, 90° left, 180°, extra angle from Settings | Transform | Multiples of 90° in MP4 and MOV set the track transform without re-encoding; other angles and containers re-encode with the fill color |
| `video.flip` | Horizontal, Vertical | Transform | Re-encode |
| `video.fps` | 24, 30, 60 | Transform | Frame dropping or duplication by timestamp; re-encode |
| `video.removeAudio` | — | Transform | Remux without audio tracks |
| `video.convert` | MP4, MOV, M4V, MKV, WebM, AVI, FLV | Transform | Remux when the target container holds the source codecs; otherwise MP4/MOV/M4V use H.264 or HEVC with AAC, FLV uses H.264 and AAC, MKV uses H.264/HEVC/VP9 with compatible AAC/Opus, WebM uses VP9 and Opus, AVI uses MJPEG and PCM |
| `video.toGIF` | GIF, GIF for X (15 MB), under Convert | Derived | In-house GIF encoder; regular GIF uses saved animation defaults, full duration unless a saved range is set; X preset respects 15 MB, 1280×1080 and 350 frames |
| `video.toAnimatedWebP` | Animated WebP, under Convert | Derived | libwebp animation encoder using saved animation defaults |
| `video.toAPNG` | APNG, under Convert | Derived | ImageIO APNG writer using saved animation defaults |
| `video.thumbnail` | First Frame, Middle Frame, Choose Frame… | Derived | PNG or JPEG per Settings, with saved quality and optional width limit |
| `video.extractAudio` | MP3, M4A (AAC), M4A (ALAC), AAC, WAV, AIFF, FLAC, OGG, Opus | Derived | Copies the stream when the target holds the source codec, else encodes; Automatic bitrate copies when possible; an explicit bitrate in Settings always encodes |
| `video.subtitles` | SRT, VTT, TXT, Translated SRT | Derived | Speech framework `SpeechAnalyzer` with `SpeechTranscriber` and audio time ranges; language from settings or the system locale; cues split at sentence boundaries, at most 42 characters per line and 2 lines; translation with the Translation framework |
| `video.background` | Remove, Green Screen, Blue Screen, Custom Color, Blur | Derived | Section 8.11 |
| `video.aiCustom` | — | Depends on plan | Section 10 |

### 8.3 Audio

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `audio.convert` | MP3, M4A (AAC), M4A (ALAC), AAC, WAV, AIFF, FLAC, OGG, Opus, CAF (PCM), CAF (ALAC) | Transform | Bitrates from settings; tags (title, artist, album, artwork) copied where the target supports them |
| `audio.compress` | 64, 96, 128, 192 kbps | Transform | Re-encodes in the same lossy format, or AAC in M4A for lossless sources and for MP3 below 128 kbps (ADR 0010) |
| `audio.normalize` | −14 LUFS, −16 LUFS, −23 LUFS | Transform | ITU-R BS.1770-4 integrated loudness; gain only, capped so the 4× oversampled true peak stays at or below −1 dBTP; the notification reports when the cap stopped short of the target |
| `audio.trim` | — (panel) | Transform | Sample-accurate for PCM and lossless; frame-accurate re-encode for lossy |
| `audio.subtitles` | SRT, VTT, TXT, Translated SRT | Derived | Same on-device transcription, translation, settings, and cue rules as video subtitles; no video track required |
| `audio.aiCustom` | — | Depends on plan | Section 10 |

Inputs: MP3, AAC, M4A, ALAC, WAV, AIFF/AIFF-C, CAF, FLAC, Ogg Vorbis, Opus. WMA is not supported.
WAV input includes RF64 and BW64. Their mandatory first `ds64` chunk supplies
64-bit RIFF and audio lengths and optional oversized-chunk lengths. Chunk
ranges are checked against those lengths and the file before replacement.
The optional size table is capped at 4,096 entries before accumulation.
AVAudioFile supplies native decoding (ADR 0010).
Audio Transform in either output mode refuses extra streams or chapters that
its output cannot preserve before writing (ADR 0010).

Before staging, audio transforms inspect tags. If the target cannot store
them, Save as New File warns and keeps the original; Replace refuses and
suggests Save as New File. Unreadable tags follow the same policy instead of
being treated as absent. Always-Derived subtitle exports keep their source.
The current Float32 audio path requires source format precision that Float32
can represent exactly for lossless conversion, normalization, and trim.
Integer sources above 24-bit and float sources above 32-bit precision are
refused before staging. Lossy targets remain available.

Chained Ogg streams are not supported. Input initialization scans Ogg pages
and rejects a new logical stream after EOS before writing any output. The
original is kept (ADR 0010).

Audio transforms preserve the source speaker layout whenever the output
encoder can represent it. Unsupported layouts fail before writing instead of
downmixing. The current MP3 and Opus implementations accept only mono and
stereo; multichannel Opus requires a future multistream implementation
(ADR 0010). AAC output supports at most six channels; raw ADTS output refuses
quadraphonic layouts. Recognized 3.0 and 5.0 AAC tags, including engine output,
are converted to canonical PCM speaker order. Center-surround AAC 4.0 remains
unsupported by the current codec path and fails before PCM reads (ADR 0010).
Unknown speaker layouts are rejected instead of being interpreted solely from
their channel count.

### 8.4 Folders

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `folder.removeDuplicates` | — (review under Ask) | Trash | Candidates pass saved filters, then size, SHA-256, and byte equality. Ask opens the keep-one panel; Keep oldest/newest proposes by modification date and moves only redundant verified copies to Trash without a panel. Equal timestamps use normalized path order. Permanent deletion always requires an alert |
| `folder.removeEmpty` | — (confirmation alert) | Trash | Recursive scan followed by the section 5 alert; selected roots are retained. Only `.DS_Store` may be ignored by default; ordinary zero-byte files remain user content |
| `folder.tree` | Copy, Save as .txt, Save as .md | Clipboard, Derived | Unicode box-drawing tree, folders first, natural order, optional folders-only output; global and Tree exclusions combined; symlinks not followed, packages not traversed |
| `folder.rename` | — (panel) | Rename | Renames the selected items, or the folder's direct children when one folder is selected |
| `folder.aiRename` | — | Rename | Section 10 |
| `folder.analyze` | — | Report | One combined report with named roots, aggregate totals, largest files, duplicate/reclaimable and empty summaries. CSV, JSON, HTML, TXT, and Markdown exports are always Derived |
| `folder.compress` | ZIP, 7z, TAR, tar.gz | Derived | libarchive; one archive per selected folder, or one archive for a multi-item selection named after the parent folder |

**Folder filters and exclusions.** Duplicate filters include minimum bytes,
ignore-empty, optional filename match, and optional modification-time match.
Name matching is case-insensitive; time matching uses modification timestamps
at whole-second resolution. Filters reduce candidates and never replace hash
and byte comparison. At least one copy per verified group is always retained.
There is no size-only or head-hash deletion mode and no Delete All choice.

Global scan exclusions and per-Tree, per-Analyze, per-Rename, per-Duplicates,
and per-Empty exclusions cover folder names, file names, and extensions.
Rules split on newline or semicolon and trim whitespace. Foundation lowercase
normalizes names and patterns before Darwin `fnmatch` with flags zero, matching
basenames rather than paths. Shell patterns support `*`, `?`, bracket classes,
and backslash escaping; wildcards may match a leading dot. Extension rules
remove one optional leading dot and match the last extension. Each feature
combines its rules with global rules. Legacy excluded folder names remain
case-insensitive literal names, including names containing glob metacharacters.
An excluded selected root or ancestor also prevents traversal.
Defaults exclude `.git`, `node_modules`, and `.Trash`.
Rules are visible, resettable, and previewable in Settings. Symlinks and packages
remain traversal boundaries. Excluded or unreadable children never prove an
ancestor empty or authorize its removal.

Analyze normalizes selected roots, removes duplicates and nested roots, and
counts each filesystem file identity once. The report retains the requested
root labels and identifies aliases or overlaps. CSV uses UTF-8 BOM and RFC 4180
quoting, with spreadsheet-formula protection for filenames. JSON, HTML, TXT,
and Markdown use UTF-8 without BOM. HTML escapes filenames and contains no
active content or network references. Report saves never overwrite, even when
the save panel offers replacement, and remain undoable.

### 8.5 Archives

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `archive.extract` | — | Derived | ZIP, 7z, TAR, gz, bz2, xz, tar.gz, RAR (read only) through libarchive into a fresh collision-safe folder named after the archive stem, including when the archive has a single top-level folder; extraction flags `SECURE_NODOTDOT` and `SECURE_SYMLINKS`, absolute and `..` entry names refused before writing, `__MACOSX` skipped, quarantine copied from the archive, output capped at the larger of 1 GiB and 1000× the archive (ADR 0010); encrypted entries open the Password panel |

### 8.6 PDFs

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `pdf.merge` | — (Page order panel when needed) | Derived | One PDF, initially in natural filename order, with page ordering before processing |
| `pdf.toImages` | PNG, JPEG, TIFF | Derived | 144 dpi from Settings; pages-folder layout by default, optional loose pages with section 3.5 names. Whole output is staged and verified before commit; loose outputs commit without overwrites and retain per-file Undo after partial commit or cancellation |
| `pdf.toText` | — | Derived | `PDFDocument.string`, pages separated by form feed; scanned PDFs fall back to Vision OCR per page |
| `pdf.compress` | — | Transform | PDFKit write options `saveImagesAsJPEGOption` and `optimizeImagesForScreenOption`; kept only when smaller than the input |
| `pdf.rotate` | 90° right, 90° left, 180° | Transform | All pages |
| `pdf.extractPages` | — (panel) | Derived | Selected pages to a new PDF |
| `pdf.split` | — | Derived | One PDF per page in a folder |
| `pdf.aiRename` | — | Rename | Section 10 |

Quick Look already previews PDFs on macOS, so there is no preview operation.

TIFF export writes every rasterized page into `stem.tiff`, using the saved
PDF image DPI regardless of the PNG/JPEG folder-layout setting. It retains
the source in both output modes and verifies the encoded page count.
Aggregate page raster storage is capped at 250 MB, including row alignment
and per-page overhead, before any rendering allocation or output write.
This bounded guard reuses PDFKit and ImageIO instead of adding a TIFF library.

Locked PDFs are refused. Unlocked encrypted PDFs support Derived operations
when their permissions allow them: page images require printing; text, merge,
page extraction and split require copying. Compress and rotate refuse
encrypted inputs in either output mode because the writers cannot preserve
protection (ADR 0010).

### 8.7 Text

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `text.encoding` | UTF-8, UTF-8 with BOM, UTF-16, Shift_JIS | Transform | Input detection order: BOM, strict UTF-8, CP932, EUC-JP; ambiguous input asks in a panel; Shift_JIS means CP932 (`kCFStringEncodingDOSJapanese`) with the unmappable policy from settings |
| `text.lineEndings` | LF, CRLF | Transform | Mixed endings are normalized |
| `text.convert` | Source-appropriate TXT, CSV, JSON, XML, HTML, Markdown, PDF, property list, YAML, TOML, SRT, WebVTT targets (section 8.13) | Derived | CSV per RFC 4180 with delimiter detection among comma, semicolon, tab, and pipe, first row as header, strings unless type inference is on; XML→JSON maps attributes to `@name`, text to `#text`, repeated siblings to arrays; INI sections become objects and `;` and `#` start comments; JSON→CSV requires an array of flat objects and fails otherwise with the offending path |
| `text.json` | Pretty print, Minify, Sort keys | Transform | Flat Pretty Print, Minify, Sort Keys leaves for JSON only. Deterministic sort options below; invalid JSON fails with line and column |

Encoding and line-ending transforms read 64 KiB chunks and write directly to
staging. Detection validates the complete input without mapping user files.
Incomplete multibyte characters and CRLF pairs carry across chunk boundaries;
BOM precedence, byte order, legacy ambiguity, replacement policies and unchanged
skips remain intact. Output text verification also decodes in chunks.
Shift_JIS preserves whole-character replacement behavior by retaining the final
grapheme. A single grapheme larger than 1 MiB in UTF-8 is refused explicitly
before it can accumulate without bound. This is not a total-file limit;
UTF-8 and UTF-16 output do not need this grapheme limit (ADR 0021).

`document.convert` exports DOCX, ODT, RTF, and RTFD to PDF or TXT.
`plist.convert` exports binary or XML property lists to JSON. Both always use
Derived commits, including when Replace is selected. HTML retains decoded
source TXT and additionally offers **TXT (Rendered)** and **PDF**. New leaves
run immediately without option panels. See ADR 0014.

Document import uses AppKit attributed strings. PDF lays out the imported text
and supported attachments on US Letter pages with 54 pt margins. This is basic
rich-text reflow, not Office layout reproduction. Original page breaks, fields,
revisions, comments, and complex tables can differ. TXT contains only the
imported string. Every document export reports these fidelity limits. Ordinary
files are capped at 8 MiB before import; ZIP document contents and RTFD packages
are capped at 32 MiB and 1,024 entries. RTFD traversal is limited to 64 levels.
Packages reject links and special files; ZIP entries must use safe relative paths.
Imported text is capped at 1,000,000 UTF-16 units and PDF at 256 pages.

HTML uses an ephemeral WKWebView with page JavaScript disabled. Content rules
and response Content Security Policy block external and data-URL loads;
a bounded custom scheme serves only static files
inside the source's parent directory after resolving symbolic links. Arbitrary
file URLs, embedded pages, and navigation are unavailable. Static resources
are limited to CSS, images, and fonts, 256 requests, 8 MiB per file, and 32 MiB
total. Rendering times out after 20 seconds. PDF uses one continuous WebKit page,
not print pagination; each edge is at most 20,000 points and total area at most
16,000,000 square points. Oversized layouts fail before PDF allocation. Rendered
TXT uses visible body text. Exports report the offline and pagination limits.

Property list conversion uses Foundation serialization and the existing strict
JSON parser. Dates use `{"$maceaseType":"date","value":"<UTC ISO-8601 milliseconds>"}`;
binary payloads use `{"$maceaseType":"data","value":"<canonical base64>"}`.
A property-list dictionary containing `$maceaseType` is escaped as
`{"$maceaseType":"dictionary","value":<original dictionary>}`. Other ambiguous
reserved-tag objects fail. Booleans remain distinct from numbers. Integers must
fit signed 64-bit storage; real numbers must be finite and retain their decimal
value when written as a Double. JSON null, duplicate keys, unsupported precision,
and dates that cannot retain milliseconds fail. XML output refuses fractional
dates that Foundation would truncate. Keys in emitted JSON are sorted by Unicode
scalar order. Input and output are capped at 8 MiB, traversal at 64 levels and
100,000 values; JSON depth is checked before parsing. XML input is checked for
duplicate keys in every dictionary before Foundation decoding. This event pass
never resolves external entities and refuses entity declarations. After
Foundation decoding, traversal charges expanded scalar and key bytes for every
occurrence, including shared binary-plist references, against the 8 MiB cap.
Base64 expansion is charged before encoding binary payloads. The existing
bounded JSON serializer enforces the output cap while writing, including the
final newline (ADR 0022). Foundation owns plist
decoding, so these bounds do not promise a strict peak allocation ceiling inside
the framework. Conversion reports that comments, order, and formatting are lost.

Markdown renders to HTML or PDF with cmark-gfm: CommonMark plus the GFM table,
strikethrough, autolink, tag filter, task list, and footnote extensions. Safe
mode omits raw HTML, including scripts, and unsafe link schemes such as
`javascript:`; every Markdown export reports this limit. HTML output is a UTF-8
document titled with the file stem and has no styling. PDF passes that HTML
through the restricted WebKit path above, with its offline and pagination
limits. Markdown input is capped at 1 MiB because deeply nested blocks allocate
far more memory than their source size; rendered HTML is capped at 8 MiB.

YAML and TOML convert to and from JSON through the typed JSON model. YAML input
uses the YAML 1.2 core schema, so `yes`, `on`, and dates stay strings. Integers
keep their decimal digits, hexadecimal and octal forms become decimal, and
floats must be finite. A libyaml event pass rejects more than 64 levels or
100,000 values, counting the size and depth of every alias expansion, before
Yams composes the document. The same pass caps expanded scalar and key UTF-8
bytes at the 8 MiB input limit, charging them again for every alias reference.
YAML-to-JSON output, including its final newline, is capped at 8 MiB while
writing. JSON strings are escaped in bounded chunks, with cancellation checks
between chunks and values (ADR 0018). Mapping keys must be strings; merge keys (`<<`) and
explicit tags other than the core types fail with their path. Duplicate keys
name the key; multi-document streams fail. JSON to YAML keeps key order and
quotes strings that YAML 1.1 or 1.2 readers could retype. TOML input and JSON
input for TOML output retain a 1 MiB resource limit. The owned C bridge uses
toml++ RAII to release tables, descendants, and results on success and failure.
TOML dates and times become their RFC 3339 text as JSON
strings: offset date-times end in `Z` or `±hh:mm`, local forms have no offset,
and fractional seconds keep up to nine digits. JSON strings never become TOML
dates. TOML infinities and NaN fail. The existing conservative NUL refusal
remains for compatibility, although the bridge passes explicit byte lengths.
TOML input containing a NUL character or a `\u0000` or `\U00000000` spelling
anywhere, including comments, fails. JSON to TOML requires an object root,
refuses null, duplicate keys, integers outside signed 64-bit range, and reals
that lose decimal precision as a Double or exceed the Foundation `Decimal`
range, such as `1e300`, and writes keys in toml++ order. Both directions reuse
the plist depth and value limits and write deterministic output. YAML and TOML
outputs are reparsed, refusing any change in values.
Generated TOML uses the 8 MiB output limit during this reparse; user TOML and
JSON input for TOML output retain their separate 1 MiB limit.

SRT and WebVTT conversion reuses the subtitle cue model and writers, preserving
millisecond timing, overlapping cues, and multiline text. Inputs accept UTF-8 BOM
and CRLF. WebVTT also accepts minute-only timestamps. The bounded plain-text
subset refuses cue settings, identifiers other than sequential SRT numbers,
NOTE/STYLE/REGION blocks, markup, and decoded text that would become SRT markup.
The error names the unsupported feature rather than silently dropping styling.
Inputs are capped at 8 MiB, 100,000 cues, 65,536 characters per line, and 9,999
hours per timestamp.

**Text semantics.** Derive-to-TXT copies decoded content without interpreting
Markdown, HTML, scripts, or source code. It always preserves the source, uses
`stem.txt`, and writes UTF-8 without BOM. TXT/text aliases have no redundant
TXT conversion leaf. Encoding and line-ending actions apply to every classified
text extension, including mixed text formats. Undecodable or ambiguous inputs
require the existing encoding flow rather than a silent UTF-8 guess.

JSON Sort Keys supports ordinal Unicode-scalar, case-insensitive, and natural
comparison, ascending or descending, recursive or root-only scope, and an
ordered pinned-key list. Pinning is case-insensitive and precedes other keys.
Comparators use ordinal tie-breaking for deterministic output. Optional
primitive-array sorting uses serialized JSON values as lexical keys, not numeric
order, and defaults off because ordering changes meaning. Object-containing
arrays retain their order. Formatting preserves values, including numeric
precision, and retains the selected indentation policy. Strict JSON remains
the input contract; comments and trailing commas are not silently discarded.

OCR files share the encoding writer. UTF-8, UTF-8 BOM, UTF-16 LE BOM, and
Shift_JIS/CP932 are available. A custom substitute must be nonempty, one Unicode
scalar, and encodable in CP932. Invalid substitutes fail inline validation.
Unmappable characters follow the saved fail, replacement, or numeric-reference
policy, with visible warnings for any substitution. Clipboard and Show outputs
keep the native Unicode text. Empty OCR or transcription produces no file and
a visible reason. Audio/video subtitle outputs use `stem.srt`, `.vtt`, or `.txt`.

### 8.8 JAR

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `jar.decompile` | — | Derived | Runs bundled `cfr.jar` with the Java found by `/usr/libexec/java_home` into a folder named after the JAR |

### 8.9 All files

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `any.checksum` | SHA-256, MD5, SHA-1, SHA-512 | Clipboard and Report | One line per file `hash  name`; Text result panel for more than one file |

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
- Output name: `stem_background.<ext>`, always Derived.

### 8.12 HDR and SDR conversion

Image and Video > Convert contain **SDR**, meaning HDR to SDR. It opens no
extra options window. Both honor the output-mode switch,
while unsupported preservation requirements still refuse Replace.

| Operation | Menu leaf | Mode |
| --- | --- | --- |
| `image.hdrToSDR` | Image > Convert > SDR | Transform |
| `video.hdrToSDR` | Video > Convert > SDR | Transform |

**Detection.** The host inspects decoded transfer functions, color primaries,
auxiliary gain maps and calibration, and available mastering or content-light
metadata. Recognized inputs include Apple capture gain maps, ISO 21496-1 gain
maps, PQ/HLG HEIC, AVIF, and JPEG XL, and HEVC HLG/PQ video including the
supported Dolby Vision 8.4 base layer. Bit depth, a wide-gamut profile, a file
extension, or mastering metadata alone does not prove genuine HDR. Capture
provenance and signalled HDR are distinguished from known SDR-expanded content.
Unknown provenance is reported as unknown, never asserted to be captured HDR.

SDR conversion applies only to HDR content. Finder Sync can identify only
potentially HDR-capable extensions, not the transfer function or capture origin.
It offers the candidate SDR leaf for those formats, with no content probing.
The host validates it and skips ordinary SDR inputs with an explicit reason.
This conservative menu visibility is not proof that a file is HDR. Known
SDR-expanded inputs retain that label in results and never acquire a claim of
genuine HDR through conversion.

**Images to SDR.** ImageIO SDR decoding, such as
`kCGImageSourceDecodeToSDR`, or a color-managed Core Image tone-mapping path
reconstructs HDR from the base and gain map or PQ/HLG signal. It maps highlight
roll-off, exposure, and gamut into the selected SDR space, sRGB or Display P3,
with the corresponding ICC profile. Display P3 is wide-gamut SDR, not an HDR
transfer function. A transfer-tag change or hard clipping is not tone mapping.
Only the SDR output drops the gain map and obsolete HDR signalling. Other
metadata is preserved subject to section 3.5. The original remains recoverable
under either commit mode. Ordinary new-file operations that cannot preserve
HDR share this decoding and tone-mapping path and report `imageToneMappedToSDR`.
They never obtain SDR by discarding a gain map and keeping the default decoded
base. Replace requires an explicit Convert > SDR operation before such edits.

The current ordinary encoder preserves gain maps in JPEG/HEIC and full-depth
PQ/HLG pixels in direct PNG/TIFF conversions, verifying the encoded transfer
profile and depth. Quantized PNG, native-HDR geometry and other encoders use
the SDR/refusal policy rather than claiming unverified HDR preservation.
Automatic tone mapping preserves frame timing and streams animated frames;
encoded raster outputs are checked for remaining HDR. Allocation limits are
checked before tone-mapping and alpha-inspection buffers. These checks do not
replace the display and peak-memory acceptance gates.

**Video to SDR.** AVFoundation/VideoToolbox performs HDR-to-SDR tone mapping
into BT.709 primaries, transfer, and matrix. Only MOV, MP4, and M4V are candidate
containers for this path. Finder omits SDR for MKV, WebM, AVI, and FLV. The host
rejects those inputs with the existing unsupported-file error before opening
AVFoundation, including direct conversion requests (ADR 0022).
The Dolby Vision 8.4 route uses the
HLG-compatible base layer and reports that the output is SDR without Dolby
Vision dynamic metadata. Unsupported Dolby Vision profiles or missing required
base-layer information fail explicitly. Audio, timing, supported streams, and
non-HDR metadata retain the section 8.2 guarantees. Alpha-bearing sources need
a compatible output path or fail before writing.

**Quality gate.** HDR-to-SDR release acceptance uses real gain-map captures and
synthetic PQ/HLG ramps, grayscale, saturated colors, highlight detail, and video
temporal patterns. Decoded results must show a monotonic grayscale response,
neutral grays, preserved highlight distinctions without hard clipping, no
unexplained hue or exposure shift, and stable mapping across frames. Encoded
color tags and actual decoded luminance must agree. Results are compared with
the color-managed platform reference and viewed on HDR and SDR displays.
Record fixtures, measured tolerances, and device findings in `docs/spikes.md`.
Both new-file and Replace, metadata, cancellation, and Undo require acceptance.
A metadata-only check is insufficient.

### 8.13 Target conversion matrix

These are target pairs, not evidence of an implemented or tested codec path.
Each row defines all source-to-target pairs in that row. Availability requires
a native macOS framework or the approved permissive/in-house backend in
sections 3.7–3.8. Container extensions do not guarantee that every contained
codec works. The host validates actual codecs before writing. No FFmpeg CLI,
Windows component, or unapproved dependency is introduced to fill a pair.

For still images, **I** is PNG, JPEG, HEIC, WebP, AVIF, JPEG XL, GIF, TIFF,
BMP, TGA, ICO, ICNS, SVG, and PDF. For video, **V** is MP4, MOV, M4V, MKV, WebM,
AVI, and FLV. For audio, **A** is MP3, M4A (AAC), M4A (ALAC), raw AAC, WAV,
AIFF, FLAC, OGG (Vorbis), Opus, CAF (PCM), and CAF (ALAC). “Except own format” uses the canonical
aliases in section 4.2. It suppresses only all-selection no-ops. An M4A source
still exposes both codec choices.

| Image inputs | Target pairs |
| --- | --- |
| PNG, JPEG/JPE, WebP, HEIC/HEIF/HIF, ICO, GIF still, SVG | Each input to every I target except its own format. PDF output always derives. These include Flect's PNG/JPG/WebP/HEIC/ICO/GIF/SVG pairs. |
| AVIF, JPEG XL, TIFF/TIF, BMP, TGA, ICNS | Each input to every I target except its own format; PDF output always derives. |
| PSD | PNG, JPEG, or TIFF using the ImageIO stored composite, always Derived. A visible warning explains that layers are not preserved in the export. The source retains its layers. Transparent composites use the configured background color for JPEG and report an additional transparency warning. |
| DNG, CR2, CR3, NEF, ARW, RAF, ORF, RW2 | Each decodable RAW input to every I target, always Derived. |
| Animated GIF, APNG, animated WebP, supported ImageIO sequences | GIF, APNG, animated WebP, retaining all frames/timing. Static targets refuse frame loss. HEICS writing is unsupported. |
| Multi-page TIFF | Multi-page PDF or TIFF with every page preserved; other destinations refuse page loss. |
| Any supported image | OCR to TXT; Make Icon (`image.iconSet`) to ICNS, ICO, or AppIcon set; Make PDF from selected images. These exports always derive. Convert > ICNS/ICO are separate Transform actions. |

Animation conversions and edits retain finite loop counts, including absent
GIF loop extensions, or refuse an unrepresentable count before writing.
GIF stores a 16-bit repeat count after the initial play; ImageIO reports
total plays. WebP stores a 16-bit total play count; APNG uses 32 bits.
HEICS writing and multi-image formats without verified timing support refuse
conversion instead of selecting a primary frame. Make PDF and icon exports
also refuse animation loss; icon exports refuse multi-page inputs.
TGA uses ImageIO only. The host exposes its destination only when ImageIO
advertises both decoding and encoding; unsupported systems fail clearly.
Generated TGA round trips were verified on macOS 27; macOS 26 device
verification remains required. No universal macOS 26 codec claim is made.

SVG input blocks scripts and network loads. SVG output explicitly selects
traced paths (1–8 colors) or Base64-embedded PNG with dimensions and viewBox.
Embedded PNG is a raster wrapper. Opaque targets cannot silently flatten alpha.
A Derived conversion can use the chosen background color only with a visible
warning. Replace refuses actual alpha loss before writing; a fully opaque
alpha channel remains valid. GIF and traced SVG also check partial alpha,
which their binary transparency cannot preserve. The same new-file warning / replacement refusal
policy applies to HDR loss, using the section 8.12 tone-mapping path. Icon and
PDF exports retain their always-Derived mode.

| Video inputs | Target pairs and codec rules |
| --- | --- |
| MP4, MOV, M4V, MKV, WebM, AVI, FLV with supported video | Each input to every V target except its own container. Remux compatible streams first; otherwise use the validated output tuples below. |
| Every supported video input | GIF, animated WebP, APNG exports; PNG/JPEG thumbnail; every A format through Extract Audio if an audio track exists; SRT/VTT/TXT and translated SRT through Subtitles. |
| HEVC PQ/HLG and supported Dolby Vision 8.4 | SDR in a compatible MP4/MOV/M4V output under section 8.12. |

MP4/MOV/M4V encode H.264 or HEVC with AAC. FLV encodes H.264 with AAC.
MKV encodes H.264, HEVC, or VP9 with AAC or Opus. WebM encodes VP9 with Opus.
AVI encodes MJPEG with PCM. Compatible existing AV1 packets may be remuxed into
containers that support them; this does not provide AV1 encoding. Alpha
re-encoding uses HEVC-alpha/ProRes 4444 MOV or VP9-alpha WebM. Flect's M4A
video-conversion target is covered by MacEase's always-derived Extract Audio >
M4A. Audio-only M4A stays in Audio and never pretends to contain video.

| Audio inputs | Target pairs |
| --- | --- |
| MP3, WAV, AIFF/AIF, raw AAC, OGG/OGA Vorbis | Each input to every A target except its own format. AIF and AIFF share one target. |
| M4A AAC or ALAC, FLAC, Opus, CAF | Each input to every A target. Same-format leaves may be pruned where the codec is known by extension; M4A variants remain visible. Both CAF codec choices remain visible because its codec is unknown by extension. |
| AIFF-C/AIFC | Every A target through the existing AudioToolbox decoder when the contained codec is supported. Unsupported codecs fail before output. |
| Every supported audio input | SRT, VTT, TXT, translated SRT via the shared subtitle pipeline, always Derived. |

Lossy rates and MP3 CBR/VBR come from Settings. Lossless output retains source
precision and speaker layout where supported, rather than forcing 16-bit PCM.
Unsupported layout, extra stream, or metadata preservation fails as specified
in sections 3.5 and 8.3. WMA is excluded from both A and the input list.

| Text source | Structural or decoded-text targets |
| --- | --- |
| CSV | TXT, JSON, XML, HTML, Markdown. Structural targets require a header and at least one row. |
| JSON | TXT, CSV, XML, binary property list, XML property list, YAML, TOML. CSV requires an array of flat objects. Property lists, YAML, and TOML use the strict typed mappings in section 8.7. |
| XML | TXT, JSON, with the documented attribute/text mapping. |
| INI, CFG, CONF | TXT, JSON, XML. CFG/CONF share INI key-value semantics. |
| HTML, HTM | TXT preserving source text; TXT (Rendered) and PDF through restricted WebKit. |
| SRT / VTT | TXT preserving source text; WebVTT / SRT within the plain-text subtitle subset. |
| Markdown, MD | TXT preserving source text; HTML and PDF through cmark-gfm safe mode and restricted WebKit. |
| YAML, YML, TOML | TXT preserving source text; JSON with the typed mappings in section 8.7. |
| TXT, TEXT | Encoding and line-ending conversions; no redundant TXT target. |
| Every other text extension in section 4.3 | TXT, preserving decoded content. This includes TSV and source code. |
| Every classified text source | UTF-8, UTF-8 BOM, UTF-16 LE BOM, Shift_JIS encoding; LF or CRLF endings. |
| JSON only | Pretty Print, Minify, Sort Keys in the same extension. |

Structural and TXT conversions always derive. CSV output uses UTF-8 BOM;
other structural outputs use UTF-8 without BOM. Encoding and JSON edits honor
the output mode. Format conversion does not claim lossless XML round trips.
Any unsupported mapping fails with an offending path rather than dropping values.

| Other sources | Target pairs |
| --- | --- |
| DOCX, ODT, RTF, RTFD | PDF and TXT through bounded AppKit import; always Derived. |
| Binary/XML plist | JSON with typed dates and base64 payloads; always Derived. |
| PDF | PNG or JPEG pages, TXT; selected pages to PDF; one PDF per page; two or more PDFs to merged PDF. Exports always derive. |
| Selected images | One PDF through Make PDF; icon files or an AppIcon set through Make Icon. These exports always derive. |
| Selected folders | ZIP, 7z, TAR, tar.gz, one archive per root; explicit aggregate creation retains section 8.4 behavior. |
| ZIP, 7z, TAR, GZ/TGZ/tar.gz, BZ2, XZ, RAR | Extracted tree, subject to password, path/link, quarantine, and expansion limits. No archive-to-archive menu or RAR creation. |
| JAR | CFR source directory, Java required. |
| Analyze | CSV, JSON, HTML, TXT, Markdown, from one combined multi-root report. |
| Folder Tree | Clipboard, TXT, Markdown; optional folders-only. |

**Evaluated and deferred.** WMA decode/encode and extraction need a maintainable
permissive ASF/WMA backend. AV1 video encoding needs timed-video rate control,
container integration, quality, performance, cancellation, and target-size proof;
libaom AVIF still support does not establish those capabilities. AVI MPEG-4
Part 2/MP3 encoding parity remains deferred; native MJPEG/PCM is the v1 target.
Alternative local transcription backends need demonstrated language/accuracy
benefit, licensed models, offline asset management, memory, and cancellation
acceptance. Apple Speech remains the v1 backend. None of these deferred choices
appears as a supported menu target.

**Safety boundaries retained.** Do not copy Flect behavior that silently drops
frames, streams, metadata, alpha, or channels, treats an oversize result as
successful target compression, removes byte-equality proof, deletes every
copy of a duplicate group, overwrites reports, or abandons durable Undo.
New-file mode does not relax these boundaries. Explicit exports disclose their
scope and omissions. Favorites, menu reordering, recursive folder media actions,
and cloud workflows are not parity requirements.

## 9. Presets

Platform presets ship as `Packages/MacEaseKit/Sources/Engine/Resources/platform-presets.json`.
User edits are stored in `~/Library/Application Support/MacEase/platform-presets.json`
and win over the bundled file per preset ID. Settings > Finder Menu can reset each
preset.

Schema: `{ "id", "name": {"en", "ja"}, "image": {...}?, "gif": {...}?, "video": {...}?, "audio": {...}? }`
with optional fields `maxBytes`, `maxWidth`, `maxHeight`, `maxFrames`,
`maxDurationSeconds`, `aspect` (`{"min": "4:5", "max": "1.91:1", "fit": "crop"}`,
fit `crop` or `letterbox`), `formats` (accepted formats; the source format is
kept when listed, otherwise the first is used), `videoCodec`, `audioCodec` and
`quality` (0 to 100).

Video compression honors the edited container and codecs. The source container
is kept when listed in `formats`; otherwise the first listed format is used.
Supported combinations are MP4, MOV or M4V with H.264 or HEVC and AAC; WebM
with VP9 and Opus; and MKV with H.264, HEVC or VP9 and AAC or Opus. Unsupported
combinations are rejected on save and before execution. Omitted formats default
to MP4; omitted codecs default to H.264 and AAC. WebM requires explicit VP9
and Opus selections (ADR 0010).

General menu slots are editable and resettable alongside platform presets.
Percentage, pixel, byte-target, and angle edits preserve stable IDs, validate
inline, and publish resolved values and labels in a new catalog version.
Engine slot values accept integer percentages from 1 to 1,000, pixel edges
from 1 to 16,384, and compression targets from 1 to 10,000 decimal MB.
The extra angle accepts finite degrees from -360 to 360 and defaults to 45.
Resetting a slot removes its override and restores its bundled value.
Existing stored byte limits retain their units. MacEase uses decimal MB
(1,000,000 bytes), not Flect's MiB values behind MB labels. Invalid values or
codec/container tuples fail on save and again during planning.

Animation defaults are width 480 px, 15 fps, 256 colors where applicable,
ordered dithering, infinite loop, and full duration. Settings can change these
without an extra per-run animation panel. The GIF for X preset retains its
size, dimensions, and frame-count limits. Frame rate and loudness expose saved
editable values without generic Custom panels.

Bundled defaults below remain editable product values, not a guarantee of an
external service's current upload limits:

| ID | Image | GIF | Video |
| --- | --- | --- | --- |
| `discord` | 20,000,000 B | 20,000,000 B | 20,000,000 B, MP4 H.264 + AAC |
| `x` | 5,000,000 B, JPEG/PNG/WebP | 15,000,000 B, ≤ 1280×1080, ≤ 350 frames | 512,000,000 B, ≤ 1920×1080, MP4 H.264 + AAC |
| `instagram` | 8,000,000 B, JPEG, width ≤ 1440, aspect 4:5 to 1.91:1 (crop) | — | Reels: 9:16 1080×1920 (crop default, letterbox option), MP4 H.264 + AAC |
| `line` | — | — | ≤ 300 s (one over-limit input opens Trim one second under the limit, then compresses; a multi-input request skips over-limit items with a reason, ADR 0010 as amended here), ≤ 1920×1080, MP4 H.264 + AAC |
| `email` | 18,000,000 B (25 MB attachment limit minus Base64 overhead) | 18,000,000 B | 18,000,000 B, MP4 H.264 + AAC |
| `web` | WebP, long edge ≤ 1920, quality 80 | — | — |

## 10. Apple Intelligence

Shown only when `SystemLanguageModel.default.availability == .available` and
AI features are on in settings. The host refreshes the menu file when
availability changes.

**Ask Apple Intelligence (natural language)** (`image.aiCustom`, `video.aiCustom`, `audio.aiCustom`). The user
writes a request such as "WebP under 1 MB, long edge 1600". A
`LanguageModelSession` with guided generation (`@Generable` plan of one to
three steps, each an operation ID and one of its menu presets) turns it into a
plan restricted to the operations of the selected kind (ADR 0010). The Ask
Apple Intelligence panel shows the plan in plain words; nothing runs until the user presses Run.
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

One **Welcome** window replaces the multi-page wizard. It shows the app icon,
**Right-click and done.**, one sentence describing the Finder workflow, and a
static MacEase screenshot of Resize > 50%, with descriptive alternative text.
No Flect tagline, illustration, or asset is reused.

The checklist contains Finder extension status with Turn On…, Notifications
with Allow, and Launch at login with its default-on switch. A short note explains
first-use protected-folder prompts for Desktop, Documents, Downloads, removable,
and network volumes, plus a Full Disk Access shortcut. Status refreshes when
the app activates. Done permits incomplete permission rows.

If translocated or outside `/Applications` and `~/Applications`, the checklist
is replaced by Move MacEase to Applications guidance and Quit MacEase. Done is
disabled until relocation. The regular window has no pages, dots, or step
animation. It supports keyboard navigation, VoiceOver states, larger text, and
Reduce Motion.

After Done, if Finder Sync remains disabled, the menu bar shows Turn On Finder
Extension… until it is enabled. Settings > General > Show Welcome Window…
reopens this window.

A normal launch without an operation, reopening the running app from Finder,
Spotlight or Dock, and `macease://open` all show Welcome if onboarding is
incomplete, otherwise Settings. `applicationShouldHandleReopen` uses the same
routing. A Finder run request routes directly to its operation and essential
panel or Activity, without opening Settings as a side effect. The extension's
Open MacEase fallback follows the same open route.

## 12. Updates

At launch and at most once every 24 hours, the host requests
`https://api.github.com/repos/TKY-27/MacEase/releases/latest`. When the tag is
newer than the running version (semantic versioning), it shows a notification
and a menu bar item linking to the release page. Nothing is downloaded or
installed automatically. Network errors are logged and ignored until the next
check.

## 13. Error handling

- Input validation accepts only regular files and directories after resolving
  symlinks. Special filesystem entries are rejected before content reads,
  including panel previews.
- Errors are typed per domain (decode, encode, commit, unsupported codec,
  permission, cancelled, target unreachable, invalid input). Each maps to a
  localized, actionable message naming the file.
- Non-finite audio samples fail decoding with a typed error. Floating-point
  input values must be finite and representable before integer conversion;
  invalid operation parameters fail validation.
- Expected per-item errors end the item as failed; the batch continues. There
  are no silent fallbacks: a fallback path (for example dav1d instead of
  VideoToolbox) is a defined behavior, not error recovery.
- Video audio conversion and extraction reject timelines requiring more than
  ten minutes of synthesized silence in total per operation. The remaining
  budget is checked before filling each gap so sparse malformed timelines
  cannot trigger unbounded output work.
- Native audio packet copies into MP4, MOV, M4V, and native audio extraction
  preserve source priming, end padding, and edited presentation times through
  edit lists and trim attachments. Matroska and WebM retain Opus CodecDelay and
  SeekPreRoll. Other copied audio in Matroska, WebM, AVI, and FLV uses whole
  packets on the edited presentation timeline, starting at or after the trim
  origin without negative timestamps. Its start may differ by up to one audio
  frame. Rate-changing audio edits fail with an unsupported-timing error before
  their packets are appended (ADRs 0023 and 0024).
- AVI indexes reject duplicate or overlapping OpenDML chunk references.
  Index reads are capped at the smaller of the file size and 128 MiB;
  records are capped at the smaller of the file size divided by the index
  entry width and 4,000,000. OpenDML references are capped at 65,536.
  These limits are checked before index allocation or record accumulation,
  and index traversal checks cancellation (ADR 0010).
- Image memory checks separate individual frames from retained frame sets.
  The 1.5 GB resident target reserves 500 MB for frameworks and leaves 1 GB
  for explicit working buffers. A single decoded frame can use that 1 GB,
  including aligned rows and frame overhead. Animated image edits decode,
  transform and encode one frame at a time. Border trimming uses a separate
  bounds-union pass; compression retries decode again and retain only timing
  summaries. GIF output uses per-frame palettes through the streaming writer;
  APNG and WebP use incremental writers. TIFF pages and image-to-PDF inputs
  retain the 250 MB cumulative cap. Transform and encoder checks
  account for additional pixel copies before allocation. Limits are estimates
  of explicit allocations, not a substitute for the Instruments acceptance
  check in section 16. Full-resolution 200 MP transforms and encoders remain
  limited by their additional buffers; accepting a 200 MP source does not
  imply that every operation fits. Broader support requires tiled processing.
  PNG conversion omits optional lossless optimization when only that step
  exceeds the workspace limit, and reports a warning. Pixels and resolution
  are preserved. PNG target-size compression also reports that warning and
  continues with its palette candidates when lossless optimization exceeds
  the budget.
- PDF-to-images and PDF OCR release each rendered page before the next.
  Each rendered page has a one-third share of the 1 GB working budget for
  its canvas, snapshot and writer or recognition buffer. Completed pages
  do not consume later pages' pixel budgets.
- ICO directory ranges must be disjoint. The icon fallback decodes only the
  largest representation. ICNS chunks are traversed sequentially. Icons keep
  their 100 MB cumulative decode and traversal cap. Eager encoded input reads
  have a separate 250 MB cap before copying. ImageIO and PDFKit do not expose
  payload offsets, so retained-image budgets and cancellation bound their
  traversal without adding format parsers (ADR 0010).
- Video re-encodes bake right-angle display rotations and mirroring into
  pixels. Stream copies retain the complete display matrix when the output
  supports it. Sheared, scaled and non-right-angle source display matrices
  fail before replacement. User-requested arbitrary-angle rotation remains
  supported (ADR 0010).
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

`scripts/bench.sh <operation> <file> [preset]` runs one operation on a copy of
the file in a scratch volume; run it under `/usr/bin/time -l` to read peak
memory. Measured on 2026-10-21 (Apple M5, macOS 27.0.1, details in
`docs/spikes.md`): media, PDF, archive, checksum and folder-compress items
peak at or below 520 MB; the idle host uses 15 MB after launch and 44 MB after
twelve heavy batches at about 0.1% CPU. Those measurements put text encoding,
line-ending and JSON formatting of 200–400 MB files at 1.2–2.5 GB.

The 2026-10-22 Release follow-up measures generated-file conversion, staged
writing and output verification in a standalone executable. A 400 MB UTF-8
fixture peaks at about 8 MB RSS for UTF-16 or CRLF output. This excludes the
host, JobEngine and final commit, so it does not establish full-app acceptance.
JSON formatting streams serialized output through the existing parser and
serializer. It still retains decoded input, parser bytes and a JSON value tree;
sorting can retain another tree. The 200 MB record fixture peaks at 917 MB RSS,
but memory depends on document shape and can still exceed 1.5 GB. Arbitrary
large JSON does not meet the memory target yet. No new total-file cap is added.
See `docs/spikes.md` for fixture definitions, run counts and measurement limits.

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
- Target-direction acceptance covers schema-2 grouping after pruning, per-leaf
  visibility and migration, stale catalogs after value edits, mixed-kind counts,
  single-input limits, every scheduled conversion pair, and explicit deferred
  capabilities. Menu presence alone does not prove a conversion works.
- Real-Mac acceptance exercises Finder invocation, retained panels, Activity's
  0.8-second delay and focus behavior, notification deduplication, Settings,
  Welcome/reopen/open routing, VoiceOver, larger text, light/dark appearance,
  Reduce Motion, Reduce Transparency, and Increase Contrast.
- Both output modes require device checks of actual final names and formats,
  original retention or Trash identity, collision races, cancellation, partial
  batch failure, history persistence, and stamp-checked Undo. Folder exports,
  loose PDF pages, and reports must never overwrite occupied destinations.
  HDR acceptance follows section 8.12, including display checks.
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
- Evaluated but deferred: AV1 video encoding, WMA read/write, AVI MPEG-4
  Part 2/MP3 encoding, and alternative transcription backends (section 8.13).
- WMV decoding, RAR creation, DRM-protected media.
- SDR-to-HDR conversion of any kind (owner decision, 2026-10-21).
- Recursive media processing of folder contents (media operations act on
  selected files only).
- Cloud upload, sharing, accounts, telemetry, crash reporting services.
- A main document window or drag-and-drop UI.
- PDF preview (Quick Look covers it).
- Windows and Linux.

## Changelog

- 2026-10-22: Preserve 16-bit SDR precision and budget drawing canvases.

- 2026-10-22: Preserve native video crop and pixel aspect in Matroska copies;
  share sample-count continuity across PCM copying and audio re-encoding
  (ADR 0026).

- 2026-10-22: Preserve Matroska display geometry in supported copies and
  re-encodes; disclose unsupported loss and refuse Replace before staging
  (ADR 0026).

- 2026-10-22: Block later file commits after history persistence fails until
  pending history synchronizes successfully (ADR 0020).

- 2026-10-22: Refuse duplicate JSON row keys in CSV and conflicting XML text
  or attribute names with the offending path.

- 2026-10-22: Detect Matroska track names and BCP47 language loss; retain
  lossless extraction precision and PCM presentation timing.

- 2026-10-22: Refuse lossless audio transforms above 24-bit integer or
  32-bit float source precision before staging.

- 2026-10-22: Refuse audio metadata loss on replacement and lossless 32-bit
  integer transforms before staging; warn about metadata loss when saving a
  new file.

- 2026-10-22: Preserve alpha during arbitrary video rotation, detect Matroska
  user tags, tone-map HDR thumbnails, and enforce metadata protection during
  explicit SDR conversion (ADR 0026).

- 2026-10-22: Preserve video alpha in compression, PQ/HLG in ordinary
  re-encodes, and metadata and track attributes in native outputs; disclose
  unsupported new-file property loss and refuse replacement. Derived exports
  always warn; encoding provenance and singleton groups are not losses.
  Dolby Vision 8.4 new-file edits keep the HLG base layer (ADR 0026).

- 2026-10-22: Keep complete dotted folder names when naming compressed
  archives, including `project.v1.zip` (ADR 0025).

- 2026-10-22: Enforce disclosed image metadata loss in new-file mode and
  refusal before replacement, preserve TIFF metadata per page during ordinary
  edits, use the output limit when verifying generated TOML, and detect pipe
  CSV delimiters outside quoted fields.

- 2026-10-22: Apply container-specific audio copy timing. Preserve native edit
  lists and Opus delay metadata; align other copied audio to whole packets on
  the presentation timeline without negative starts (ADR 0024).

- 2026-10-22: Preserve native audio priming and presentation timing across
  packet-copy paths; refuse rate-changing audio edits (ADR 0023).

- 2026-10-22: Strip TIFF metadata per page and inspect every page before
  skipping. Bound repeated binary-plist values during JSON traversal and
  generation. Restrict video SDR input to MOV, MP4, and M4V (ADR 0022).

- 2026-10-22: Stream text encoding, line-ending transforms and verification;
  bound Shift_JIS grapheme retention, stream JSON serialization and record
  remaining parser-memory limits (ADR 0021). Drain eager-input read pools and
  remove registered test support folders at process exit.

- 2026-10-22: Journal Trash-backed history deltas with immediate synchronization,
  checkpointed replay and atomic compaction, preserving undo, stamps and
  100-batch retention while making per-batch history writes linear (ADR 0020).

- 2026-10-21: Apply explicit image property-loss warnings in new-file mode,
  configured-background flattening, shared HDR-to-SDR tone mapping, and typed
  replacement refusals across image outputs. Treat dangling symlinks as occupied
  names and advance every collision retry (ADR 0019).

- 2026-10-22: Bound YAML alias-expanded scalar and key bytes before composition
  and JSON output during cancellable writing. Detect duplicate XML plist keys
  before Foundation decoding without entity expansion (ADR 0018).

- 2026-10-22: Retain failed staging removals for later recovery and wait up to
  five seconds for cancelled jobs during normal quit, while preserving accepted
  undo requests and the history termination barrier (ADR 0017).

- 2026-10-21: Record measured section 16 memory, idle and storage results.
  Chunked file reads no longer accumulate whole files, text line-ending and
  UTF-16 conversions drop redundant copies, Images to PDF streams pages instead
  of refusing large selections, and release DMGs use LZMA (ULMO).

- 2026-10-21: Replace TOMLKit with vendored toml++ 3.4.0 behind an owned C
  bridge, preserving typed mappings and limits while releasing conversion
  allocations. Pin source provenance and add repeated-conversion resident
  memory regression checks (ADR 0016).

- 2026-10-21: Expose ALAC audio extraction and CAF codec targets; classify
  AIFF-C, PSD composites, and capability-gated TGA; export every PDF page to
  TIFF at the saved DPI; refuse frame/page loss and retain finite animation
  loop counts (ADR 0015). PSD and PDF exports always retain their sources.

- 2026-10-21: Add Markdown HTML/PDF through swift-cmark 0.9.0, YAML/JSON
  through Yams 6.2.2, and TOML/JSON through TOMLKit 0.6.0 with exact pins,
  committed resolution, generated notices, and bounded typed mappings (ADR 0014).

- 2026-10-21: Add bounded document PDF/TXT, offline HTML PDF/rendered TXT,
  typed plist/JSON, and plain-text SRT/WebVTT conversions through Finder and
  Derived commits. Document fidelity, resource, and mapping limits (ADR 0014).
  Markdown HTML/PDF and YAML/TOML mappings await verified package integration.

- 2026-10-21: Wire the new folder, text and menu settings into Settings: duplicate filters and keep
  policy, exclusion rules per scope, OCR file encoding, custom Shift_JIS
  substitute, JSON sort options, SVG mode, PDF page layout, and editable menu
  values with inline validation and reset. Duplicate, Empty Folders, and Analyze
  scans run in Activity; Analyze exports in five formats and combines roots.
  Activity counts skips separately from problems. The sidebar page is named
  Text Recognition & AI.

- 2026-10-21: Implement U5 engine settings for verified duplicate filters and
  automatic Trash retention, shared feature exclusions, OCR encodings and
  substitution warnings, embedded-PNG SVG, loose PDF page images, editable
  catalog slots, and SHA-1/SHA-512 leaves. Settings controls are wired separately.

- 2026-10-21: Drop SDR-to-HDR conversion from the target; HDR-to-SDR stays.
  Prefer proven, license-compatible libraries and components over custom
  implementations when they give a better result (ADR 0013).

- 2026-10-21: Adopt the Flect-style menu-first target v1, schema-2 preset
  groups and selection pruning, essential panels, Activity feedback, sidebar
  Settings, per-preset visibility, and single Welcome/open routing. Default
  transforms to collision-safe new files with Undo; retain optional safe
  Replace. Expand functional and conversion scope, define HDR-to-SDR and the
  experimental SDR-to-HDR quality gate, and permit copyleft source study
  without code reuse. See `adr/0013-flect-style-menu-first-direction.md`.

- 2026-10-21: Compare structured HDR calibration by value, decode ISO RGB
  auxiliary rasters through Core Image, and normalize gain-map orientation
  independently from the base image
  (`adr/0012-gain-map-calibration-and-raster-decoding.md`).

- 2026-10-21: Preserve ISO and Apple HDR gain-map geometry and calibration
  across supported JPEG/HEIC edits. Refuse unsupported map transformations
  before replacement. Accept engine-written 3.0/5.0 AAC layouts; retain the
  typed guard for center-surround AAC 4.0 after codec verification (ADR 0010).

- 2026-10-21: Accept RF64/BW64 WAV inputs with ds64 size checks. Permit
  unlocked encrypted PDFs for Derived operations according to permissions,
  while retaining encrypted replacement refusal. Honor edited video preset
  containers and codecs with save-time and runtime validation (ADR 0010).

- 2026-10-21: Stream animated image edits and compression passes instead of
  retaining every decoded frame. Border trimming retains only union bounds;
  frame timing and per-frame allocation checks remain intact (ADR 0010).

- 2026-10-21: Separate still-frame, retained-image and encoded-input budgets.
  PDF page export releases completed pages. Transformation and encoder
  workspace checks replace the global ten-copy assumption. Generic 200 MP
  operation support still requires tiled processing (ADR 0010).

- 2026-10-21: Multi-image decode and PDF rendering enforce cumulative pixel
  budgets; ICO rejects shared ranges and its fallback keeps one image.
  Video edits preserve display mirroring and reject unsupported source
  matrices before replacement (ADR 0010).

- 2026-10-21: Non-finite samples and invalid numeric parameters fail safely.
  Media replacements reject unpreserved streams before writing (ADR 0010).
  All commit modes and undo check cancellation inside file coordination.

- 2026-10-21: Chained Ogg inputs fail before writing and retain the original
  (ADR 0010). Input validation rejects special filesystem entries before
  operation or preview reads.

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
