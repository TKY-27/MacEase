# MacEase Specification

This document is the single source of truth for MacEase. It describes the
finished product, including the v2 additions in section 20 and v3 in sections 24 and 25. When code and this
document disagree, this document wins;
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
  limited to Resize, Compress and Playback Speed. Other windows collect essential input,
  confirm destructive work, or present results.
- **Never lose a file.** An original is never modified or removed until the
  output is fully written and verified. HatchZip is the explicit exception:
  verified, durable output replaces archive bytes progressively (section 8.5). Replaced originals go to the Trash and
  every batch can be undone.
- **Local only.** All processing is on-device. No telemetry. The network is
  used for update checks, explicitly requested media downloads, temporary
  user-started private-LAN sharing, and OS-managed model and asset downloads.
  The v3 enhancement models ship with the app; no runtime model download or
  model-installation UI is required. Other local file operations remain offline.
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
FinderSync/               Finder Sync extension sources, assets, Info.plist, entitlements, String Catalog
Packages/MacEaseKit/      Swift package (MenuCatalog, Formats, Engine) and its tests
Vendor/deps.lock          Pinned native dependency versions, URLs and SHA-256
Vendor/patches/           Patches applied to native dependency sources, if any
scripts/                  build-deps.sh, make-dmg.sh, create-signing-identity.sh,
                          generate-notices.sh, bench.sh
docs/                     SPEC.md, adr/, spikes.md
project.yml               XcodeGen project
Makefile                  Developer entry points (see CONTRIBUTING.md)
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
  "schema": 4,
  "catalogVersion": "SHA-256 of a length-prefixed encoding of entries, moreTitle and commands",
  "token": "64 hex characters",
  "hostAvailable": true,
  "moreTitle": "More",
  "commands": [
    { "group": "command.preview", "title": "Show Finder Preview", "placement": "primary" },
    { "group": "command.copyPath", "title": "Copy Path", "placement": "primary",
      "leaves": [{ "preset": "posix", "title": "Copy Path" },
                 { "preset": "shellQuoted", "title": "Copy Path for Terminal" }] },
    { "group": "folder.downloadMedia", "title": "yt-dlp…", "placement": "finder" }
  ],
  "entries": [
    { "op": "image.resize", "preset": "percent-50", "kind": "image", "path": ["Resize", "50%"],
      "separatorBefore": false, "operationSeparatorBefore": false,
      "groupID": "image.resize", "placement": "primary" }
  ],
  "kinds": { "image": { "title": "Images" } }
}
```

- `entries` lists every visible menu leaf in display order, already localized
  in the host's UI language and already filtered by settings and capabilities
  (hidden items, Apple Intelligence availability, Java availability).
- `path` gives the localized submenu titles from the kind level down to the leaf.
  Different operation IDs can share a submenu, such as Rotate and Convert.
- `separatorBefore` marks a preset-group boundary at that leaf's parent level;
  `operationSeparatorBefore` marks a boundary between operation clusters.
  After filtering, the renderer keeps group boundaries between surviving groups
  without leading, trailing, or repeated separators. Separators have no action
  or entry index. Section headers are not used.
- Every entry carries a required `placement`: `finder` (directly in Finder's
  context menu), `primary` (the MacEase submenu) or `more` (the final More
  submenu). Section 4.2 describes the arrangement that produces it.
- `commands` lists the Commands rows (section 4.5) in display order. Each row
  names its group, a localized title and a placement. Host command groups use
  the `command.` prefix; other groups, such as `folder.downloadMedia`, refer to
  operation entries. Optional `leaves` list the localized choices of a command
  submenu, each with a `preset` that the request carries.
- The host omits a command row it cannot offer: Update without a known newer
  release, Move Here without cut items, and New File without enabled templates.
  The host rewrites the menu file whenever one of these conditions changes.
- The catalog hash covers the complete ordered entries, including grouping,
  placement, parameter values, visibility, and selection constraints, plus
  `moreTitle` and every command row and leaf. Each field is hashed with a
  64-bit big-endian length prefix, an absent value uses length −1, and lists
  are preceded by their counts, so titles cannot imitate a field boundary and
  an absent value differs from an empty one. Kind titles are not hashed.
  Editable menu values are published with their stable slot IDs and resolved
  parameters. Leaf constraints include minimum and maximum per-kind counts and
  applicable source and target formats. The host validates the parameters again
  before execution. `resizeValue` carries the resolved integer percentage or
  pixel edge for its stable resize slot; `targetBytes` carries decimal
  compression bytes.
- Entries may carry stable recipe IDs, revisions and accepted-kind sets.
  The catalog hash includes these fields. Recipe inputs must all match the
  accepted kinds; the host never silently drops unsupported files.
- `token` is generated once from 32 random bytes on first launch, persisted by
  the host, and rotatable in Settings > Advanced.

If the menu file is missing, unreadable, uses an unsupported schema (including
schemas 1 to 3), or has a `catalogVersion` that does not match its content, the
extension shows a single item, "Open MacEase", which opens `macease://open`.
The host rewrites the file at launch, so a schema-3 file left by an older
version is replaced on the first launch after an update. The host shows Welcome
if onboarding is incomplete, otherwise Settings. This route never runs an
operation.

**Menu construction.** Finder Sync copies menu items and keeps only title,
image, action and `tag`; `representedObject` is lost (verified). Each menu the
extension builds takes a fresh contiguous tag range: operation entries first,
then one tag per command action. The per-process counter starts at a random
value between 1 and `Int32.max / 2` and never wraps; when a build would pass
`Int32.max`, the extension shows only Open MacEase. The extension retains the
last eight builds, and a tag resolves only within the build whose menu showed
it, carrying that build's catalog version. A click on a menu shown before the
menu file changed therefore sends the old version and receives the stale-menu
notification. Action handlers run off the main thread (verified: isolating the
class to the main actor crashes the extension). They only read `sender.tag`,
read the selection from `FIFinderSyncController`, build the URL, and call
`NSWorkspace.shared.open`.

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
- Every request path, in run and command requests alike, must be absolute,
  contain no NUL and no `.` or `..` component. Repeated and trailing slashes are
  removed before the host calls `lstat` or touches the file system, so a
  trailing `/` or `/.` cannot defeat symbolic-link refusal.
- URL hosts compare case-insensitively through one shared rule for `run`,
  `open`, `update`, `preview` and the Finder commands.

`macease://update?t=<token>` opens the host's single Update window. It requires
exactly one token matching the current menu file and an available host. The
host shows the window only while a newer release is known. It needs no catalog
version, entry index or selection, and never starts jobs or writes history.

`macease://preview?t=<token>` turns the saved Finder Preview setting on when it
is off and off when it is on (section 25.1). Like Update, it requires exactly
one matching token and an available host, without a catalog version, selection
payload, job or history record. The extension sends only the token for Update
and Preview and does not read the Finder selection for them; the host never
treats either route as a Finder command request.

```
macease://<command>?t=<token>&v=<catalogVersion>[&preset=<preset>]&path=<path>…
```

The Finder commands of section 4.5 use the hosts `newfile`, `cut`, `movehere`,
`copypath` and `openterminal`. A command request requires exactly one token
matching the current menu file, an available host, exactly one `v` equal to the
current catalog version, at most one `preset`, and at least one valid `path`.
The command and preset must be one the current menu file publishes; otherwise
the host shows the stale-menu notification. Folder destinations are checked
again in the host as existing directories that are not packages. Rejected
requests (malformed URL, wrong token or unavailable host) are logged and show
nothing else.

**Threat model.** The token stops web pages and documents from triggering
operations through the URL scheme. Local processes running as the same user can
already modify the user's files and are out of scope. Permanent deletion normally requires a confirmation alert. The authenticated
`archive.hatchExtract` action is the sole exception: it immediately consumes
the selected archive through its durable extraction protocol without an alert.
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
  originals untouched. HatchZip uses a separate durable path: cancellation pauses
  extraction, preserving extracted files and recovery state.
- Each item ends as `succeeded`, `skipped(reason)` or `failed(error)`. One item
  failing never stops the rest of the batch.

### 3.5 File commit model

Each operation resolves to one commit mode before processing. Settings > General
has **Saving Results** with two **Save results** choices:

- **Save as new file** (default). Transform operations use Derived commits.
- **Replace original (move original to Trash, Undo)**. Transform operations use
  the Replace sequence below.

The default applies to new installs and existing installs without an explicit
saved output-mode choice. A saved choice is preserved. Each batch snapshots
its resolved mode and settings, so later Settings changes cannot alter a job.
The photo/video editor chooses this mode per save through its split Save button,
independently of the global setting (section 8.1.1).
Finder Preview is read-only and writes no files. History records of the
removed `text.edit` operation from version 3.1.0 still load, display as
**Edit Text** and remain undoable.

**Transform** in section 8 means this switch applies. It covers image resize,
compression, conversion, rotation, flip, border trimming, background editing,
and metadata stripping; video resize, trim, compression, rotation, flip,
frame-rate changes, remove audio, and container conversion; audio conversion,
compression, normalization, and trim; PDF compression and rotation; text encoding,
line endings, and JSON formatting or sorting.

Exports, extracts, and reports keep their inputs regardless of the switch,
except explicitly requested HatchZip in-place extraction (section 8.5).
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
| Line endings; JSON | `stem_lf.ext`, `stem_crlf.ext`; `stem_pretty.ext`, `stem_min.ext`, `stem_sorted.ext` |
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

**Exclusive publication.** Derived outputs (single and grouped),
different-name Replace outputs, renames, moves, new files and Undo restores
publish through one exclusive step. On volumes that support it, this is
`renamex_np` with `RENAME_EXCL`; a cross-volume staging move (`EXDEV`) keeps its
existing `FileManager` move without overwriting. When the volume returns
`ENOTSUP` or `EOPNOTSUPP` (exFAT and FAT32 on macOS 27.2.1), the publisher
reserves the final name with an exclusive `open` or `mkdir`, confirms the
reservation's identity and renames over it. An occupied name advances the
collision numbering; a failure names the destination path and removes only a
reservation that still matches the one it created. `docs/spikes.md` records the
remaining interval between the reservation check and the rename. Same-name
Replace keeps its clone, Trash and `replaceItemAt` sequence.

**Moves.** `files.move` publishes items the user cut (section 4.5) into a
destination folder. Each item keeps the size, modification date and identity
captured at cut time; a changed or missing item is skipped as
`changedSinceScan`. A move on the same volume is one coordinated exclusive
rename that keeps the item's file-system identity, numbers collisions and
records an ordinary Rename entry; Undo renames it back, including when a parent
folder is reached through a symbolic link. A move to another volume never
removes the original. It copies the item with `copyfile` into staging on the
destination volume without following symbolic links, keeping sparse files
sparse where the volume supports it, then verifies kind, bytes, tree shape and
link targets, and publishes the copy exclusively. It records one Derived entry
and the warning that names both paths and says the original was kept. Undo
moves an unchanged copy to the Trash and skips an edited or missing one; the
original is unchanged in every case. Copying and verification run outside the
naming lock and the history gate. Dataless cloud files are downloaded before
copying. Moving a folder into itself or one of its subfolders is refused. Only
regular files, folders and symbolic links can be moved; other file types such
as FIFOs and sockets are refused without being opened. Trash access to the
source is not required.

**New files.** `folder.newFile` creates one file from a built-in template in
the target folder: Text (`.txt`, empty), Markdown (`.md`, empty), Rich Text
(`.rtf`) or Word (`.docx`); the RTF and DOCX templates are minimal documents
written through `NSAttributedString`. The name is the localized **Untitled**
plus the template extension, numbered like other Derived names, and is never
published over an existing file, folder or dangling link. Verification uses a
separate new-file check: Text and Markdown may be empty, while RTF and DOCX
must open as their document type, chosen by the final file name. This is the
only exception to the non-empty output rule; transforms, exports and reports
keep it. The file is recorded as Derived; Undo moves an unchanged file to the
Trash and skips an edited one. Targets that are not folders, are packages or
are symbolic links are skipped, and unwritable folders fail with a permission
error.

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

**HatchZip exception.** `archive.hatchExtract` does not use Replace, Trash, or
ordinary temporary staging. It reserves a collision-safe permanent folder on the
source volume, validates the archive, and durably publishes each extracted unit
before releasing its source bytes. Its private session records and upstream
checkpoints survive pause, failure, app exit and ordinary staging/history cleanup.
Completed extraction records are not undoable. RAR extraction, ZIP member
exports and new extractions of archives whose names need CP932 retain the
ordinary Derived behavior. See section 8.5 and ADRs 0040 and 0083.

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

The isolated download runtime includes MIT-licensed QuickJS-NG 0.18.0, built
from source with a solver-only CLI and pinned by SHA-256 in
`Vendor/media-tools.lock` (section 22). Its patch, CLI source and license accompany
the source distribution.

Libraries linked into MacEase are permissively licensed and compatible with MIT
distribution. Sections 22–24 permit separately licensed isolated tools and
models; these are not linked-library license exceptions. Versions are
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

Archive readers register decompression filters explicitly, and every
registration must return `ARCHIVE_OK` before a source opens (ADR 0083).
General readers enable gzip, bzip2, xz and zstd only; ZIP-based document
validation enables none. No reader enables program filters or a filter that
can fall back to an external executable, so no archive operation starts a
decompressor process. ZIP's own compression methods belong to the ZIP format
reader and need no outer filter.
| libdeflate | MIT | Optimized DEFLATE for PNG and ZIP | CMake |
| CFR | MIT | JAR decompilation (bundled `cfr.jar`, run with the user's Java) | Downloaded jar |
| toml++ 3.4.0 | MIT | TOML parsing and emitting | Vendored single header, C++17 behind an owned C bridge |
| ICU 78.3, Apple ICU 76 data | Unicode-3.0 | Bounded natural JSON comparison across known macOS collation generations | Filtered static data and adapted disk-backed iterators (ADR 0032) |
| Swift CoreFoundation comparison shell | Apache-2.0 with Swift Runtime Library Exception | Preserve Foundation natural-order semantics | Adapted behind the JSON comparison C bridge; source revision pinned |

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
into MacEase source or linked libraries. Section 22 explicitly permits isolated
LGPL FFmpeg executables and their required LGPL dependencies for downloads,
under section 23 local MP3 encoding, and under section 25.3 decoding local
media the native engine cannot read into a staged intermediate. Keep them
separate processes with corresponding source and license notices. Section 24 additionally permits the
unmodified standalone GPL-2.0-only gallery-dl runtime through its public CLI,
with its own license and exact corresponding source. Never link or incorporate
its GPL implementation into the MIT app. Local enhancement uses separately
licensed models and isolated native audio executables as specified in section
24.3; it does not incorporate GPL-family implementations. This supersedes ADR 0004's prohibition on reading those sources.

Flect is Apache-2.0 and is the interaction reference. Its developer's permission
to study or reuse it does not replace license terms. MacEase independently
implements the design in Swift and reuses only facts and data, such as extension
lists, menu taxonomy, and preset values. No Flect code or assets are reused.
If code is ever copied, retain the Apache-2.0 license and applicable notices,
mark modifications, and include NOTICE and attribution in
`THIRD_PARTY_NOTICES.txt` as required by the license and project policy.
See `adr/0013-flect-style-menu-first-direction.md`.

The bundled HatchZip helper uses `hatchzip-core` 0.1.10 at commit
`e56b4ceca0d28e967ce04834895e693c84a2a7a0` (MIT OR Apache-2.0), with UnRAR
disabled. Its source archive is pinned in `Vendor/deps.lock`; its Rust
dependencies are locked and their notices accompany the helper.

The v3 toolkit resources are built with `make toolkit`: `build-age.sh`,
`build-ai-audio.sh` and `build-upscaler.sh` under `scripts/`. `make bootstrap`
also installs missing Go and Python 3.11 and builds the toolkit before project
generation. `make media-tools` rebuilds the isolated download runtime.

| Resource | Pin and license | Distribution boundary |
| --- | --- | --- |
| gallery-dl | 1.32.20, GPL-2.0-only; source SHA-256 and runtime dependencies in `Vendor/media-tools.lock` | Unmodified private-Python CLI, own license and matching source in media-tools |
| age bridge | Official age v1.3.2, BSD-3-Clause; `Vendor/AgeBridge/go.mod` and `go.sum` | Separate `Contents/Resources/macease-age` executable and dependency notices |
| Swin2SR classical SR ×2 | Revision `cee1c923c6a37361c6e5650b65dcf4be821e5d52`, Apache-2.0; `Vendor/upscaler.lock` | `Contents/Resources/upscaler/Swin2SR.mlmodelc`, model card and license |
| Native audio inference | sherpa-onnx 2.0.1, Apache-2.0, commit `af2d8d81dbfa61c4cea4c568da78f3982edca005`; ONNX Runtime 1.28.2, MIT | `Contents/Resources/ai-audio`, two native executables, dylib and third-party notices |
| GTCRN / Spleeter 2stems | MIT models; hashes, sizes and provenance evidence in `Vendor/ai-audio.lock` | Bundled ONNX models, validation report, manifest and licenses |

Audio runtime distribution includes Eigen 5.0.1 MPL-2.0 corresponding source
and all runtime notices. Spleeter adoption requires exact comparison against
Deezer's original checkpoint and the metadata-only 44,100 Hz correction; the
archive/checksum-index discrepancy is documented in `docs/ai-audio.md`.
The build-only Python environments and PyTorch/Transformers conversion code
are not inference dependencies shipped for these features. Build scripts may
fetch pinned resources; application inference never downloads models.

### 3.8 Format implementations

Independent codecs and containers live in `Formats`; isolated MP3 output lives
in `Engine`. Each has independent output tests. SSIM is computed on the luma
channel against the source.

| Component | Scope | Algorithm | Done when |
| --- | --- | --- | --- |
| MP3 output | MPEG-1 Layer III, 44.1 and 48 kHz, mono and stereo, CBR 128/192/256/320 kbps and VBR quality 0–9 | Independent bundled FFmpeg/libmp3lame process; section 23 supersedes the former in-house encoder | AudioToolbox decodes every frame without error; on the music fixture at 192 kbps the segmental SNR is at least 20 dB and bandwidth is at least 16 kHz; encoding runs at least 20× real time on M1 |
| GIF encoder | Single and animated | Color quantization in Oklab (Wu initial palette refined by k-means), global or per-frame palettes, Floyd–Steinberg or ordered dithering (setting), transparent-pixel frame differencing, LZW | ImageIO decodes it; SSIM ≥ 0.93 on the gradient video fixture at 256 colors with dithering; output is smaller than ImageIO's GIF output for the same frames |
| PNG lossy quantizer | RGBA to ≤ 256-color palette with alpha (tRNS) | k-means in premultiplied Oklab with alpha, optional dithering, libdeflate compression with per-row filter selection | SSIM ≥ 0.97 and size ≤ 45% of lossless libdeflate PNG on the photo fixture |
| PNG lossless optimizer | Re-encode PNG without changing pixels | Bit depth and color type reduction, sampled filter selection and libdeflate; balanced effort for conversion and static RGB8 target compression, bounded stronger fallback on the remaining target paths | Decoded pixels identical; standalone optimization is never larger than the input (otherwise keep input bytes) |
| Matroska and WebM | Demux and mux; video H.264, HEVC, VP8, VP9, AV1; audio AAC, Opus, Vorbis, FLAC, MP3, AC-3, PCM; BlockAdditions for VP9 alpha; Cues and SeekHead | Per the Matroska specification (RFC 9559) and the WebM container guidelines | Round-trip mux and demux preserves packets and timestamps; Chrome-compatible WebM (VP9 + Opus) plays in WKWebView; AVFoundation-independent tests pass |
| AVI | Demux (OpenDML included); mux MJPEG + PCM | Microsoft AVI RIFF specification | Files from common encoders open; MJPEG + PCM output opens in QuickTime-compatible players |
| FLV | Demux; mux H.264 + AAC or 44.1 kHz mono/stereo PCM16 | Adobe FLV specification v10.1 | Round-trip preserves packets and timestamps |
| ICO | Write with PNG-compressed entries 16–256 px; read | Microsoft ICO format | ImageIO reads every entry |
| ICNS | Write with PNG payloads (`ic07`–`ic14`); read | Apple ICNS format | ImageIO and NSImage read every size |
| SVG tracer | Monochrome and up to 8 colors | k-means color layers, marching squares contours, Douglas–Peucker simplification, cubic Bézier fitting (Schneider), stacked filled paths | Re-rasterized intersection-over-union ≥ 0.95 per color layer on the logo fixture |
| Target-size planner | Images, GIF, video, audio | See section 8.10 | Output ≤ target and ≥ 92% of target on the fixtures |

Ogg pages use libogg; the in-house code only arranges packets and granule positions.

## 4. Finder menu

### 4.1 Scope and selection

Finder registration does not grant filesystem access. Folder Access shows
registration separately from read checks; a successful check confirms directory
listing only, not permission for every child or write. Removing an additional
folder removes its explicit registration, not macOS permission or eligibility
under root monitoring. Adding uses NSOpenPanel. Bookmarks refresh on launch,
configuration changes and volume events. Unavailable entries remain removable.

Some iCloud-managed locations suppress Finder Sync menus. The native Finder
Services action **MacEase…** offers the same enabled, applicable
catalog entries and routes them through the normal host validation and job
pipeline. It reads file URLs only; it never authorizes an arbitrary command.
Only Release builds declare the service, so development copies never add a
second, app-name-qualified item.
The setting explains this fallback and links to macOS permission settings.

- `directoryURLs` includes `/`, home, standard user folders, iCloud Drive and
  its Desktop/Documents locations, every mounted volume root, and explicitly
  added folders. Host-owned bookmarks resolve folder moves without mounting
  unavailable volumes. The resolved paths are an optional menu-file field;
  absent fields decode as empty. Notifications only trigger a reread. Workspace mount,
  unmount and rename notifications refresh registration outside menu handlers
  (ADR 0033). Local, separate-volume and network paths require release checks.
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

One top-level **MacEase ▸** uses the extension's Context Page template glyph
(ADR 0027). The user arranges every menu scope in Settings > Finder Menu
(section 7); the defaults follow section 4.4 (ADR 0079). Each scope (Commands,
then each kind including All Files) has the sections **MacEase Menu**, **More** and
**Hidden**; Commands also has **Finder Menu**, whose groups appear directly in
Finder's context menu outside MacEase. Within a section, groups keep the order
the user chose. Hidden groups are not published.

Inside MacEase, the Commands groups placed in MacEase Menu come first (section
4.5), followed by one separator. A single kind then exposes the groups of its
MacEase Menu section directly. All Files groups placed in MacEase Menu follow
behind a separator. A final separator and **More ▸** (Japanese: **その他**) hold
the More sections of the selected kinds, then the More section of Commands,
separated from each other. Empty More menus disappear. Mixed selections retain
`MacEase ▸ Kind (n) ▸ Operation ▸ Choice` for MacEase Menu groups, with All
Files groups inline after the kind submenus. Their single final More menu uses
`Kind (n): Operation ▸ Choice`, without another kind submenu, keeping every
path within four levels. Counts and single-selection limits use that kind's
subset. Unknown files and packages receive All Files operations. Folder
selection never enables recursive media operations. The folder-background
**yt-dlp…** item is a Commands group placed in Finder Menu by default.

When the host is available and knows a newer release, the default Commands
arrangement shows **Update Available (v3.1.0)** (Japanese:
**アップデートがあります（v3.1.0）**) first inside MacEase. The version is
dynamic. Its cached, non-template SF Symbol uses system blue; Finder Sync does
not preserve attributed title colors. It opens the authenticated Update route,
independently of the selection. Unavailable hosts never show this item.

**Show Finder Preview** (Japanese: **Finderプレビューを表示**) follows Update by
default. While the saved Finder Preview setting is on, the host rewrites
menu.json so the item reads **Hide Finder Preview** (Japanese:
**Finderプレビューを閉じる**); Finder Sync does not reliably show checkmarks, so
the title states the action. The item is available for every selection,
including unknown types and folder backgrounds, whenever the menu advertises it
and the host is available.

Positions never adapt to usage. Pruning a group for the current selection never
promotes another group from More. Shared Rotate/Flip and Convert/SDR/animation
groups move together; JSON commands have individual groups. A group shown in
Finder Menu, MacEase Menu or More always keeps at least one visible leaf: when
the last checked leaf of a group is unchecked by any path, or when turning off
the extra angle removes Rotate's only checked leaf, the group moves to Hidden in
every affected scope and its new-install leaves are restored. The same rule
runs at launch. Cluster separators between operations are kept while a section
retains its default order and dropped once the user reorders it. Reset All
clears the arrangement.

Only image/video Resize and image/video/audio Compress have **Custom Size…**.
Flip leaves share Rotate. Video animation leaves share Convert. JSON commands
are flat operation-level leaves. Separators divide preset groups.
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
- Audio Trim, Choose Frame, and Extract Pages require exactly one input of that kind. PDF Merge requires two or more PDFs.
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

The first table gives the default MacEase Menu order and default More groups
of each kind; the user can rearrange them (section 4.2). The Commands scope
defaults are in section 4.5. Semicolons separate visible groups. The second
table lists preset groups; semicolons there render as separators. `hidden` means hidden only on new
installs. Single leaves and count constraints follow section 4.2.

| Kind | Primary groups, in order | More groups |
| --- | --- | --- |
| Images | Edit Photo…; Convert; Compress; Resolution; Rotate; Background; Recognize Text | Upscale Photo…; Make PDF; Make Icon; Trace to SVG…; Trim Borders; Remove Metadata; Rename with Apple Intelligence… |
| Videos | Edit Video…; Convert; Compress; Resolution; Extract Audio; Thumbnail; Subtitles | Rotate; Playback Speed; Remove Audio; Frame Rate; Background |
| Audio | Trim…; Enhance Audio…; Convert; Compress; Normalize Loudness; Subtitles | — |
| PDFs | Edit Pages…; Merge…; Export as Images; Export as Text; Compress; Rotate; Extract Pages…; Split into Pages | Rename with Apple Intelligence… |
| Documents / Property Lists | Convert | — |
| Text | Convert; Pretty Print; Minify; Sort Keys | Encoding; Line Endings |
| Folders | Compress; Rename…; Organize…; Analyze…; Remove Duplicates…; Remove Empty Folders… | Folder Tree; Rename Contents with Apple Intelligence… |
| Archives | Extract with HatchZip; Extract RAR; Browse Contents… | — |
| JAR | — | Decompile |
| All Files | — | Finish With Recipe…; Share with QR Code…; Find Related Files…; Encrypt or Decrypt…; Checksum |

Remove Duplicates omits its ellipsis under an automatic keep policy.
Every operation absent from the primary table defaults to More, in catalog
order. All Files groups default to More. Groups added by a later version are
appended to More in scopes the user has customized.
The arrangement is stored in UserDefaults under `menu.arrangement` as
`{"version": 1, "scopes": {scope: {section: [groupID]}}}`, holding only
customized scopes; a scope equal to its defaults is not stored. Group IDs, never
localized paths, identify groups. Unreadable arrangement data is copied to
`menu.arrangement.unreadable`, logged, and replaced by the defaults. On the
first launch with this model, the legacy `menuPlacements` choices and groups
whose leaves were all hidden migrate once into the arrangement, which
reproduces the previous menu; the folded groups' leaf keys leave the hidden
list except for new-install defaults, and `menuPlacements` is deleted and never
written again. A later launch never migrates again. Layout partitions indexed
entries once and preserves original request indices. Removed operation
visibility keys are discarded; a hidden `video.trim/` migrates once to
`video.edit/`.

| Submenu | Groups in display order |
| --- | --- |
| Image Resize | 75%, 50%, 25%; Long Edge 3840 px (hidden), 2560 px (hidden), 1920 px, 1080 px, 720 px, 480 px, 360 px; Custom Size… |
| Image Compress | Discord (20 MB), X (5 MB), Instagram (8 MB), Email (18 MB), Web; High Quality, Medium Quality, Low Quality; Custom Size… |
| Image Convert | PNG, JPEG, HEIC, WebP, AVIF, JPEG XL; GIF, TIFF, BMP (hidden), TGA; ICO (hidden), ICNS (hidden), SVG, PDF; SDR when applicable (section 8.12) |
| Image and video Rotate | 90° Right, 90° Left, 180°, 45° (hidden, editable extra-angle slot); Flip Horizontal, Flip Vertical |
| Background | Remove, Green Screen, Blue Screen, Custom Color, Blur; Color Key for images only |
| Remove Metadata / Recognize Text | All, Location Only, Selected Fields / Copy Text, Save as .txt, Show |
| Make Icon | macOS Icon (.icns), iOS AppIcon Set, Windows Icon (.ico) |
| Video Resize | 50%; 2160p (4K) (hidden), 1080p, 720p, 480p, 360p; Custom Size… |
| Video Thumbnail | First Frame, Middle Frame; Choose Frame… |
| Audio and video Subtitles | SRT, WebVTT, Plain Text; Translated SRT |
| Video Compress | Discord (20 MB), X, Instagram Reels, LINE, Email (18 MB); 10 MB, 25 MB, 50 MB, 100 MB (hidden); High Quality, Medium Quality, Low Quality; Custom Size… |
| Video Convert | MP4, MOV, M4V (hidden), MKV, WebM, AVI (hidden), FLV (hidden); GIF, GIF for X (15 MB), Animated WebP, APNG (hidden); SDR when applicable |
| Extract Audio | Original (first), M4A (AAC), M4A (ALAC), MP3, AAC, WAV, AIFF (hidden), FLAC, OGG (Vorbis) (hidden), Opus (hidden) |
| Audio Convert | MP3, M4A (AAC), M4A (ALAC), AAC, WAV, AIFF, FLAC, OGG (Vorbis), Opus, CAF (PCM), CAF (ALAC) |
| Audio Compress | 192 kbps, 128 kbps, 96 kbps, 64 kbps; Custom Size… |
| Normalize Loudness / Frame Rate | −14 LUFS, −16 LUFS, −23 LUFS / 24 fps, 30 fps, 60 fps |
| Encoding / Line Endings | UTF-8, UTF-8 with BOM, UTF-16, Shift_JIS / LF (macOS, Linux), CRLF (Windows) |
| Folder Compress / Folder Tree | ZIP, 7z, TAR, tar.gz / Copy, Save as .txt, Save as .md |
| Checksum | SHA-256, MD5, SHA-1 (hidden), SHA-512 (hidden) |

Platform size labels are generated from saved preset limits, never hardcoded
beside editable values. General percentage, pixel, angle, byte-target,
frame-rate and loudness slots are edited in the Options… sheets of Finder Menu
(section 7). Text conversion pairs are specified in section 8.13.

### 4.5 Finder commands

The Commands scope holds host commands that act on the Finder selection without
an operation entry. Its default arrangement places, in this order, Update
Available, Finder Preview, New File, Cut, Move Here, Copy Path and Open
Terminal Here in MacEase Menu, and yt-dlp… in Finder Menu. The user can reorder
them, move them to Finder Menu or More, or hide them (section 4.2). Each command
appears only for the selections listed below and runs through the request route
of section 3.3 (ADR 0080).

| Command | Offered for | Behavior |
| --- | --- | --- |
| **New File ▸** Text, Markdown, Rich Text, Word | A folder background, or one selected folder that is not a package | Runs `folder.newFile` (section 3.5) through JobCenter with Activity, history and Undo, then selects the new file in Finder |
| **Cut** | One or more selected items (not a folder background) | Records each item's stamp off the main actor and writes the file URLs to the general pasteboard |
| **Move 1 Item Here** / **Move {n} Items Here** | A folder background, or one selected folder, while cut items exist | Runs `files.move` (section 3.5) into that folder |
| **Copy Path ▸** Copy Path, Copy Path for Terminal | Any selection, or the folder of a background click | Copies one POSIX path per line, or space-separated paths quoted for a POSIX shell |
| **Open Terminal Here** | One selected item, or a folder background | Opens Terminal in the folder, or in the parent of a file or package |

New File lists the templates enabled in `finderCommands.newFileTemplates`;
all four are enabled by default, and with none enabled the command is omitted.
Template names use the localized **Untitled** (Japanese: **名称未設定**).

A new Cut replaces the previous set; repeated items count once. While items are
being recorded, Move Here is hidden and a direct request fails with an
explanation; a newer Cut cancels an earlier recording. MacEase checks the
pasteboard's change count every 0.5 seconds while cut items exist. When another
application or a later copy changes the pasteboard, the cut set is cleared and
menu.json is rewritten. Every Undo request, a quit request and termination also
clear it; a cancelled quit keeps the commands available. Ordinary Finder Paste
of the cut URLs copies them as Finder always does.

Move Here is hidden while a move runs, so it cannot be submitted twice. Items
moved on the same volume and items skipped because they changed since Cut leave
the cut set. Failed items and items copied to another volume stay in it with
their original stamps. When the whole set is done and the pasteboard still holds
MacEase's cut, the pasteboard is cleared; after a partial move it is rewritten
with the remaining items; content another application wrote is left alone.
Moving to another volume copies and keeps the original (section 3.5); Activity
details name the destination and say where the original was kept.

Copy Path for Terminal leaves a path unquoted when it contains only ASCII
letters, digits, `/`, `.`, `_` and `-`; otherwise it single-quotes the path and
escapes embedded single quotes. A pasteboard write failure is reported.

Open Terminal Here opens the folder with
`NSWorkspace.open(_:withApplicationAt:configuration:)` and the application at
`finderCommands.terminalApplication`, which defaults to
`/System/Applications/Utilities/Terminal.app`; an empty or relative saved value
uses that default. It sends no Apple events. A missing application or an open
failure is shown in the failure panel even when notifications are off.
Reset All Settings restores both command settings.

## 5. Panels

Windows appear for essential per-run input, destructive review, results, and
explicitly requested Finder Preview (section 25.1).
They use native title bars, system controls, grouped forms, and system colors.
Flect supplies interaction structure. Finder copy windows and macOS Settings
supply layout conventions. Decorative cards, gradients, custom glass content,
and repeated explanatory labels are excluded, consistent with the
[Impeccable slop catalog](https://impeccable.style/slop/) and
[Apple menu guidance](https://developer.apple.com/design/human-interface-guidelines/menus).

Input panels center on the active screen, accept Return for the action and Esc
for Cancel, and focus the first field. They validate inline and disable invalid
actions. Forms are about 420 pt wide, media panels 600 pt, with content-driven
heights that support larger text. Keyboard controls provide alternatives
to dragging. Reduce Motion, Reduce Transparency, and Increase Contrast use
system behavior. Values are remembered only for retained panels.

| Panel | Used by | Contents |
| --- | --- | --- |
| Size | Image/video Resize > Custom Size… | Width and Height in pixels, live result for the first file. One blank dimension preserves proportions; both fit inside the box. Images have Allow enlarging. No mode picker. |
| Target size | Image/video/audio Compress > Custom Size… | One decimal size field, largest-selected-file hint and live byte equivalent. Image requests expose Allow downscaling; other processing options remain in Settings. No quality/platform picker. |
| Photo / video editor | Images or videos; over-limit LINE clips with a preselected range | Resizable dark workspace: unified toolbar with centred tool tabs, large viewer with centred transport, sectioned right inspector; video timeline below. Section 8.1.1. |
| Speed | One or more videos, Custom Speed… | Numeric playback speed, presets, current save policy. |
| Trim | Audio trim | Resizable dark window with a full-width waveform timeline, centred transport and Start/End/Length timecodes (section 23.2). |
| Frame picker | Single video Choose Frame… | Preview and timestamp. |
| Page order | PDF Merge, Make PDF with multiple images | Thumbnails, reorder/remove, Move Up and Move Down. |
| Page select | Single PDF Extract Pages… | Page ranges and thumbnails. |
| Rename / AI rename | Rename requests | Prefix, suffix, find/replace, numbering (start, step, digits), creation/EXIF date, live preview table; AI suggestions remain editable and require confirmation. |
| Duplicates | Ask every time, the default keep policy | Opens after the scan finishes in Activity. Verified groups with keep-one choices, oldest/newest proposals, reclaimable bytes, Move to Trash. Permanent deletion requires an additional alert. |
| Analyze | Selected folder roots | Opens after the scan finishes in Activity. One combined report, named roots, totals, largest 50 files, size by type, duplicate and empty summaries, and Export… with a format pop-up (CSV, JSON, HTML, Plain Text, Markdown) that starts at the Settings default. |
| Text result | OCR Show, multi-file checksum, report details | Read-only text, Copy and Save. |
| Password / Encoding | Engine requests | Secure archive password field remembered only for the batch, or ambiguous source text encoding. |
| Panel failure | Failed panel preparation | Actionable failure and retry or close. |

Angle, Animation, Background, Subtitles, Extract Audio, and generic Options
panels are removed. Their values move to Settings as listed in section 7.
The Empty Folders checklist is replaced by a confirmation alert after scanning
in Activity. It lists at most 12 paths and the remaining count, with Move to
Trash and Cancel. Permanent deletion uses Delete Permanently and defaults to
Cancel. No excluded or unreadable descendant can make a parent deletable.

## 6. Progress and feedback

One shared **Activity** window shows all running batches. Automatic display is
on by default, including after Reset All Settings. The v2.2 migration enables
it once for existing users; subsequent explicit preferences are preserved.
Users can also open it from the menu bar or Window menu. If enabled, it appears
only if a batch is still running after 2 seconds. It is a
nonactivating, closable NSPanel at normal level, about 420 pt wide, with an
autosaved frame on the active space. It never takes focus from Finder. Scans
for duplicates, empty folders, and Analyze use the same window.

Each batch row shows operation and count, current filename, completed/total,
a determinate progress bar or indeterminate scan, and a separately labelled
Stop button. Rows use spacing rather than cards. Status is **Done.**,
**Finished with {n} problems.**, **Finished — {n} skipped.**,
**Finished with {n} problems, {m} skipped.**, **Cancelled.**, or **Failed.**
Skipped items and warnings on successful items are not problems. Successful
results use a success symbol and normal text color even when notes are present.
Warnings appear as secondary notes behind a compact **1 note** / **{n} notes**
disclosure with an info.circle symbol (Japanese: **メモ {n} 件**). Repeated notes
appear once with the affected file count; the disclosure count sums distinct
notes per file. File Results and Show All retain individual file notes.
Failures use xmark.octagon.fill and the error color; skips stay neutral.
Failure headlines name the action, file, cause and next step. Associated decode,
encode, commit, unexpected-error, unsupported-codec and malformed-input
diagnostics appear as
selectable text in a collapsed **Details** disclosure (Japanese: **詳細**).
After five problems, **More Results** reveals the remaining rows and their
diagnostics, including batches without a comparison or retry session.
Scan rows read **Scanning {folders}…** with an indeterminate bar until the
scan reports progress; Stop cancels the scan and opens nothing. Finished rows
offer Show in Finder and Undo when applicable.

A file that stopped because it holds content the output cannot carry over
(section 8.2) is a question, not a failure. Its status line reads **1 file
needs your confirmation.** / **{n} files need your confirmation.** with an
accent question-mark symbol and primary text; when real problems are present,
both status lines show, and VoiceOver reads both. One grouped box below the
problem list names the content: one statement for a single file, or an
introduction and every affected file with its kinds, without a cap. A plain
sentence per kind says what leaving it out means, then a sentence says what
happens to the originals: in Replace mode the files are replaced and the
originals move to the Trash with Undo; otherwise new files are made and the
originals stay. Nothing is collapsed. The button names up to two kinds
(**Continue Without Timecode**, **Continue Without Subtitles and Timecode**) and
reads **Continue Without Them** for three or more. It resubmits only the
affected files, and each file's consent covers only the kinds reported for that
file and the file version that was inspected. It runs once per result;
afterwards the row reads **Continued without {kinds}. The new result is
below.** and the new batch appears as its own row. Leaving or dismissing the
row declines; nothing is written before the button is pressed. Such a result
makes Activity appear without activating MacEase, even when Show Activity
automatically is off or the batch ended within two seconds; it never closes
automatically, and no notification banner is posted for it. **Retry Failed…**
never resubmits files that only await this question.

General settings default to close After success on, After cancellation on,
After failure off. Success with notes reports Done and stays visible; skips also
stay visible. The window closes
when no rows remain. Closing Activity hides it without cancelling jobs. Stop
cancels the chosen batch. Turning Show Activity automatically off keeps menu-bar and
notification feedback.

The menu bar keeps active batches, Cancel, Results, and the last 10 batches
with Undo and Show in Finder. General > Menu Bar has **Show in menu bar** (on)
and **Show recent operations** (on). Turning Show in menu bar off removes the
status item at once; turning it on restores it (ADR 0081). Notifications and
Activity keep working while it is hidden, and opening MacEase again (from Finder, the
Applications folder or `macease://open`) opens Settings, or Welcome until setup
is done. Show recent operations hides only the Recent block and is disabled
while the status item is hidden. The update item, Turn On Finder Extension…,
Show Activity, In Progress with Cancel and Pause, Results, **Finder Preview**,
Settings…, Check for Updates and Quit MacEase are not optional. Finder Preview
shows a checkmark while the saved preview setting is on and toggles the same
setting as the Finder command. **Show Progress** appears while jobs run. The
status item uses the Context Page template glyph (ADR 0027). While busy, its
highlighted row steps through three frames every 0.4 s; with Reduce Motion on,
a static busy frame shows instead. An attention badge appears when the latest
batch has failures other than cancellation, or when Finder Sync is disabled
after onboarding. Opening the menu or a later successful batch clears it.
The status item retains the native labels **MacEase**, **MacEase, processing**,
and **MacEase, needs attention**.

`UserNotifications` sends at most one completion banner per batch, with counts,
the first problem, Undo, and Show in Finder. Fully successful batches show only
the completion summary and a note count when needed, never note text. Raw engine
diagnostics stay out of notification bodies. A completed row retained and visible
in Activity suppresses its duplicate banner. Successful rows that auto-close
still produce the banner. Failure-only batches notify when Activity is disabled
or was closed by the user. Notification denial leaves results in Activity and
the menu bar. Stale-menu and permission notifications remain actionable.

### 6.1 Dismissing results and update attention

Failed results remain visible in Activity until dismissed or its window is
closed. Dismissing a result or closing Activity removes completed rows,
session-only comparison and retry data, and matching delivered notifications.
Dismissal from Notification Center removes the matching completed Activity row.
Running jobs can be shown again; paused extraction recovery, durable history,
and Undo remain available. Automatically closed results do not reappear. The
menu bar marks an available update with an attention glyph and update-specific
accessibility label, and places its Update window action first. Opening the menu
does not clear update availability.

Invalid inputs become per-item skipped or failed results while valid items
continue. Per-file problems never open modal alerts. Panels validate inline.
Alerts remain for blocking app states, failed history flush on quit,
Remove Empty confirmation, and permanent-delete confirmation.

## 7. Settings

Settings uses a resizable `NavigationSplitView` sidebar and grouped detail forms,
with a minimum size of 720 × 520 pt. The sidebar lists pages in four unlabeled
groups separated by spacing: General, Finder Menu, Finder Windows, Folder
Access; Images, Video, Audio, Text & PDF, Folders, Text Recognition & AI;
Organization, Finishing Recipes; Advanced, About. Changes apply immediately and persist in
host `UserDefaults`, except preset overrides in section 9. There are no Apply
or OK buttons. Language changes ask before relaunch because active jobs stop.

| Page | Settings and defaults |
| --- | --- |
| General | Language (System, English, Japanese), Open at login (on), notifications, Check for updates automatically (on). Saving Results: Save results — Save as new file (default) / Replace original (move original to Trash, Undo); If some content can’t be kept — Ask (default) / Save without it (applies only to results saved as new files and to Finishing Recipes; Replace always asks; section 8.2). Show Activity automatically (on); Close automatically After success (on), After cancellation (on), After failure (off). Menu Bar: Show in menu bar (on), Show recent operations (on, disabled while the status item is hidden). Allow permanent deletion (off). Show Welcome Window… |
| Folder Access | Locations: standard and additional folders with access-check status, Add Folder…, Remove from List, Check Access, Show in Finder. Access and Availability: Extension Settings…, Files & Folders…, Full Disk Access…, Refresh. |
| Finder Menu | One organizer per scope, chosen with **Menu for** (Commands, then each kind and All Files). One list shows MacEase Menu, More and Hidden, plus Finder Menu for Commands, with drag reordering within and across sections and multiple selection, Move Up / Move Down (Option-Command-Up/Down), Move To, a context menu, expandable leaf checkboxes with "n of m items", capability and fixed-item notes, VoiceOver position values, and per-scope Restore Defaults… with confirmation. The last checked leaf of a group cannot be unchecked ("Hide it instead to remove it from the menu."). Options… sheets hold Images/Videos Resolution slots, Videos Compress MB slots and platform presets, Images Compress platform presets, Images/Videos Rotate extra angle (45°), Videos Frame Rate values and Audio Normalize Loudness values, each with one Reset for the sheet. In Commands, Open Terminal Here ▸ Options… chooses the app (Terminal by default; iTerm, Ghostty, Warp, WezTerm and kitty when installed, found by bundle identifier without launching them; Other… opens an application panel); a saved app that no longer exists shows "“name” can’t be found. Choose another application." New File ▸ Options… has Text, Markdown, Rich Text and Word template checkboxes, all on; with none checked New File is left out of menu.json and its row reads "No templates selected". |
| Finder Windows | Finder Preview: Show Finder Preview beside Finder windows (off). Storage Bar: Show storage bar in Finder windows (on), with the hint "To see it, choose View > Show Status Bar in Finder." while Finder's status bar is hidden. Permissions: Accessibility and Automation status, read without prompting, with Open Settings… when not allowed. File Types: Source code and text, HTML, Markdown, SVG, PDF, Fonts, Images, Video, Audio, Archives (all on; off uses the macOS preview). Text: code font (System Monospaced or an installed monospaced family), code font size (12, 9–24), wrap long lines (on). Fonts: sample text (empty uses the built-in sample). Trusted Folders: Add Folder… and Remove. Section 25. |
| Images | Default Quality per format, Optimize PNG files when converting, Target-Size Compression (Allow lower resolution, Allow lower frame rate), GIF dithering, Remove Metadata fields (EXIF, GPS, maker notes, comments, XMP, IPTC), platform GPS policy, Background: Subject to keep (Subject default, or Person), Green Screen color (#00B140), Blue Screen color (#0047BB), Custom Color and blur radius, Color key and its tolerance, Corner color for rotation (transparent when possible or a chosen color), SVG Method (Trace shapes or Embed PNG) and Colors (1–8). |
| Video | Codec for re-encoding (Auto, H.264, HEVC), Priority (speed or quality), Allow lower resolution and Allow lower frame rate, Corner color, editable frame-rate values, animated-image width/fps/colors/dithering/loop/range defaults for GIF/WebP/APNG, thumbnail format/quality/maximum width, Subject to keep (Person default), transparent-video format. Frame-rate menu values are in Finder Menu > Videos > Frame Rate > Options…. |
| Audio | Default Bitrate per format, MP3 mode (CBR/VBR) and VBR quality, extracted-audio bitrate (Automatic (keep original when possible) copies the stream, explicit rates re-encode). Loudness menu values are in Finder Menu > Audio > Normalize Loudness > Options…. |
| Folders | Verified duplicate matching, minimum bytes (0), ignore empty files (on), optional name/time match (off), Ignore hidden files, copy to keep (Ask every time default, Keep oldest, Keep newest), excluded folder names plus an Exclusion Rules sheet for folder, file, and extension patterns per scope (all folder scans, Remove Duplicates, Remove Empty Folders, Folder Tree, Analyze, Rename), folders-only Tree (off), empty-folder definition, rename defaults, archive defaults including exclusion of `.DS_Store`, `__MACOSX`, and AppleDouble files from new archives, Analyze default export format (CSV). |
| Text & PDF | Characters Shift_JIS cannot encode (fail default, ?, numeric references, or validated custom substitute), JSON indent (2, 4, tab), Sort keys comparison (ordinal default, case-insensitive, natural), ascending/descending (ascending), recursive/root-only (recursive), Keys to put first (empty), primitive-array sorting (off), CSV type inference (off). PDF section: page image resolution (144 dpi), layout (pages folder default, loose files optional). |
| Text Recognition & AI | OCR languages and output default (clipboard), OCR file encoding (UTF-8 default, UTF-8 BOM, UTF-16 LE BOM, Shift_JIS), spoken language, subtitle format and translation target, Use Apple Intelligence. Audio and video share subtitle settings. |
| Advanced | Concurrency, Security: Create New Token, History: Clear History…, Reset All Settings… with confirmation, Troubleshooting: Logs (Open Console), Copy Diagnostics. Full Disk Access stays on Folder Access and Welcome. Reset preserves history and preset overrides unless explicitly selected. |
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
Saved changes rewrite menu schema 4 and its catalog hash. Per-scope Restore
Defaults… returns that scope's order, sections and leaf checkboxes to the
new-install defaults and keeps Options… values. Reset All stores an empty
arrangement. Moving a group out of Hidden whose leaves are all unchecked
restores its new-install leaves. Options sheets keep Reset enabled while a
field shows a rejected value and clear it on Reset.

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
| `image.edit` | — (editor) | Transform | One decoded still image: geometry, color, styles, automatic correction, comparison and session Undo. HDR color edits and RAW outputs always keep the original. Section 8.1.1. |
| `image.resize` | 25%, 50%, 75%, long edge 360, 480, 720, 1080, 1920, 2560, 3840 | Transform | Lanczos via Core Image; keeps format, metadata and every animation frame; never upscales unless Allow enlarging is enabled in the Size panel or saved resize settings |
| `image.compress` | Discord, X, Instagram, Email, Web, High, Medium, Low quality | Transform | Size targets per section 8.10; quality presets map to per-format quality values; PNG uses lossy quantization; keeps format unless the preset requires another (Instagram requires JPEG) |
| `image.convert` | PNG, JPEG, HEIC, WebP, AVIF, JPEG XL, GIF, TIFF, BMP, TGA, ICO, ICNS, SVG, PDF | Transform (always Derived for RAW/DNG/PSD inputs and PDF output) | Animated inputs retain all frames and timing in GIF, APNG, or animated WebP; incompatible targets fail before writing. Multi-page TIFF to PDF keeps all pages; other targets must preserve all pages or fail; SVG uses Trace or Embedded PNG per Settings; embedded output retains raster appearance and never claims vector tracing |
| `image.traceSVG` | — | Derived | One static PNG; comparison, color and detail controls, then explicit SVG save; section 8.14 |
| `image.rotate` | 90° right, 90° left, 180°, extra angle from Settings | Transform | Multiples of 90° on JPEG without gain maps change only the orientation tag (lossless); HDR JPEG rotates base and gain-map pixels together; other angles rotate pixels with transparent corners, or the fill color when the format has no alpha, subject to the HDR preservation guard in section 3.5 |
| `image.flip` | Horizontal, Vertical | Transform | Pixel flip, orientation reset to 1 |
| `image.trimBorders` | — | Transform | Removes uniform borders matching the corner color within tolerance |
| `image.background` | Remove, Green Screen, Blue Screen, Custom Color, Blur, Color Key | Transform | Subject mask from Vision `GenerateForegroundInstanceMaskRequest` (all instances), person mask option, or color key with tolerance; mask edges feathered 1 px; Remove outputs alpha and converts to PNG when the source format has no alpha (JPEG, BMP) |
| `image.stripMetadata` | All, Location Only, Selected Fields | Transform | Pixels untouched for JPEG (`CGImageDestinationCopyImageSource`), PNG and TIFF (stored pixels with new metadata); HEIC re-encodes at the settings quality because macOS keeps its metadata otherwise (ADR 0010) |
| `image.ocr` | Copy text, Save as .txt, Show | Clipboard, Derived, Report | Vision `RecognizeTextRequest` accurate, language correction on, languages from settings with automatic detection |
| `image.toPDF` | — | Derived | One PDF from all selected images, initially in natural filename order; Page order panel when more than one image |
| `image.iconSet` | macOS icon (.icns), iOS AppIcon set, Windows icon (.ico) | Derived | Non-square inputs are padded to square with transparency; AppIcon set writes `Contents.json` and the sizes Xcode 26 expects |
| `image.aiRename` | — | Rename | Section 10 |

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

Resolution & Size is distinct from compression: resizing has no byte target,
uses existing format/quality settings, and preserves aspect ratio. The new
360/480/720-pixel image presets and 360p video preset never enlarge; smaller
inputs skip with a reason. Video p values refer to the short edge.

### 8.1.1 Photo and video editor

The editor opens from Finder and Services. Its initial content size is
1280×720, constrained to the active screen, with a 960×600 minimum; a single
source names the window. Window proportions do not change the source or output
aspect ratio. Like common media editors it always uses the dark appearance. A
unified toolbar centres Video (video only), Adjust, Styles, Crop and Markup,
and keeps Compare Original, session Undo/Redo, Cancel and a prominent split Save button
at its trailing edge. Undo is a split control whose dropdown offers Reset All
Edits; there is no separate More menu. A large viewer sits left of a 300-point inspector.
Video adds a transport bar under the viewer (position/duration clock, previous
frame, play/pause, next frame, preview mute, loop and Save Frame) and a
full-width timeline with Split, Freeze Frame, Reverse, Duplicate, Delete, a
segment menu, Remove Silence…, Add Music…, Add Videos… and zoom. Clicking the
clock makes its time editable; Return seeks there. Photos show Fit, 100%, 200%
and 400% under the viewer, plus pinch zoom and Command-plus, Command-minus and
Command-0. Percentages count real pixels: 100% is one image pixel per screen
pixel, as in the Finder Preview image viewer. Fit is an explicit state; at Fit,
and at any pinch or keyboard level between the steps, the current percentage
appears beside the control. Resizing the window keeps a chosen percentage, an
image smaller than the viewer can still zoom out to 100%, and Crop always
previews at Fit. The inspector groups adjustments into Light, Color and
Detail, lists styles as selectable rows, and uses tiles for rotation, flips and
aspect ratios. Video's inspector holds only selected-segment controls (Start,
End and Length as m:ss.sss timecode, speed, volume, fade) and source notes.
Speed is a 0.5×/1×/1.5×/2×/4× segmented preset plus one numeric custom field.
**Apply Adjustments to All Segments** copies the selected segment's
adjustments, and **Apply Style to All Segments** copies only its style.
Without a selected segment, segment controls are disabled and the inspector
reads "Select a segment in the timeline to adjust it." A separate pinned Export
section with output resolution sits above the pinned foot, which shows output
size, video duration, save progress and validation or save problems. Photo
lists offer Copy Edits to Selected and Copy Edits to All Photos. Unchanged or
invalid edits disable Save.

Clicking Save or pressing Return always saves a new file and preserves the original.
The editor stays open and disabled while its batch runs, showing JobCenter
progress in the foot. Success closes it. Failure keeps it open with the first
item's one-line reason and Save enabled for a retry; cancellation keeps it
open silently. Closing the editor never cancels the save.
After partial photo success, saved photos leave the session; retry saves only
the remaining photos, including after cancellation. Undo/Redo retains only the
remaining photos' edits. Saving pauses active playback. Keyboard shortcuts also
leave the workspace disabled while saving, including playback and transport.
The dropdown offers **Replace Original**, with a secondary hint that the original
goes to the Trash and can be undone. The editor ignores the global output-mode
setting. Each action resolves one settings snapshot used for both batch planning
and execution, so new-file saves use the `_edited` name and replacement saves
do not add new-file naming. Replace Original is disabled for multiple video
sources, sources requiring a new file, and HDR color edits. Only these forced
cases show a one-line reason in the output summary. Photo selections evaluate
every changed photo already opened in the editor; unopened photos keep the
engine's per-photo HDR rule. Preview SDR permission
follows source and edit requirements, independently of the global setting.

Both media types offer exposure, brightness, contrast, highlights, shadows,
saturation, vibrance, warmth and tint. Photos also offer black point, sharpness,
noise reduction and vignette. Styles are Original, Vivid, Warm, Cool, Dramatic
and Monochrome with adjustable intensity; these are independent presets and
claim no compatibility with Apple's Photographic Styles. Photo Auto Enhance
analyzes the original once per source and retains its correction before manual
adjustments. Histograms and slider tick rows are not displayed or computed.

Crop supports corner/edge drags, moving the selection, percentage fields,
free/original aspect, 1:1, 4:3, 3:2, 4:5, 16:9 and portrait/landscape switching.
Quarter turns, horizontal/vertical flips and ±45° straightening share the
geometry model. Straightening fills the canvas without introducing corners.
Coordinates are normalized, top-left, after source orientation and before
output resize. Processing order is source orientation, geometry/crop,
automatic correction, style, manual adjustments and output resize. Preview and
export use the same Core Image transforms and color processing.

Video has a single-source segment timeline with independently scrubbed output
playhead, selected-segment trim handles, numeric source start/end, actual-frame
stepping and timeline zoom. Command-B splits the selected segment at the playhead;
Backspace deletes it and closes the gap. Visible buttons and the context menu
provide split, delete, duplicate, and move left/right; drag-and-drop reorders
segments. With one segment, dragging across it scrubs instead. A duplicate receives a new identity. Split children inherit adjustments.
Each mutation or completed drag is one session Undo operation. A slider drag or
a numeric field edit is one Undo step; Start and End commits are separate,
ordered steps that always leave a valid range, and Undo/Redo cancel a pending
boundary edit. Up Arrow and Down Arrow move the playhead to the previous or next
segment boundary. "Preparing preview…" appears only when preparation takes
longer than 300 ms. Editor shortcuts match characters rather than key
positions, except named arrow keys, and leave text fields alone. Text editors keep
their normal editing keys. C selects the segment under the playhead. Empty
timelines disable playback and Save, retaining Undo.

The timeline follows the playhead. An explicit move (arrow keys, J/K/L, a
ruler click, the clock or a VoiceOver adjustment) scrolls the playhead into
view. Playback pages forward only while following is on: starting playback
with the playhead visible turns it on, and a manual scroll or pinch zoom turns
it off. The timeline never scrolls during a trim or playhead drag.

For VoiceOver the timeline is a layout area labelled "Timeline" (Audio Trim's
is "Waveform"). The playhead is an adjustable element whose increments step one
frame, valued "time of duration". Each segment reads "Segment 2 of 4", with the
source file name when several videos are joined, then its start, end and length
and Freeze Frame, Reversed, a speed such as 2× or Selected. Markup bars read
their item, such as "Box 1", with "part 1 of 2" when one item shows in several
places; the music bar reads "Music" with the song, range and volume; and while
Remove Silence… is open, each hatched range reads "Pause to remove, 1 of 3".
Pressing an element selects it. Segments offer the context menu's edits as
VoiceOver actions (Set In Point, Set Out Point, Split, Insert Freeze Frame,
Reverse Segment or Play Segment Forward, Duplicate, Move Left, Move Right and
Delete), each one Undo step and none while a reverse or save runs. Music and
segment volume sliders speak percentages, and the playhead clock says that its
time can be edited. These semantics have not been checked in a real VoiceOver
session.

A control disabled for a reason the user cannot see states the reason in its
tooltip and VoiceOver hint, for example "Place the playhead inside this
segment to split it.", "A freeze frame can’t be reversed.", "Reverse works on
segments up to 1:00 long. Split this segment first.", "This video has no
sound." or "Up to 50 items." Remove Silence… is disabled when nothing audible
remains, and the timeline context menu shows Reverse Segment checked on
reversed segments.

Speed (0.5–4×, pitch preserving), volume (0–100%), fades, color and styles belong
to the selected segment. Fade In and Fade Out (presets None, 0.25, 0.5, 1, 2, 3
and 5 seconds; at most 10) ramp the picture from or to black and the sound from or
to silence linearly in output time. Fades keep their lengths while they fit the
segment; when a later trim or speed change makes them overlap, both shrink
proportionally. Splitting keeps fades only at the outer edges. Older segment
records decode with no fades. Preview uses audio-mix volume ramps and the same
Core Image color scaling as export. Preview compositions, inserted ranges,
freeze ticks and audio ramps use a 60,000 time scale, which represents 59.94 fps
frame durations exactly; nanosecond edit times combined with 48 kHz audio need a
common scale above CoreMedia's 32-bit limit and silenced the preview after
cuts. Audio trim refuses fades longer than the kept
range and explains why inline. Geometry, crop, orientation and resolution belong to the entire
output. Segments may repeat or reorder source ranges. Preview and export share
the output-time mapping, and export encodes a continuous video/audio stream with
exact frame cuts. There is no keyframe/exact mode control in this editor. A temporary
playback copy never becomes the export source. Closing cancels tasks, releases
players and removes registered temporary files. No persistent edit project is
created. Each drag becomes one session Undo operation; preview generations
prevent older work from replacing the latest edit.

`ImageEdit` is a typed `image.edit` operation. `VideoEdit` accepts an ordered
segment array with source ranges and per-segment settings. Older records without
segments retain their single-range behavior and neutral defaults for geometry,
adjustment, style, volume and source stamp fields. Static images use existing decoders; animations and multipage
images are rejected without flattening. RAW edits use the decoded rendering
and derive a writable output. Source identity is checked at opening, saving and
after export; changes require closing and reopening the editor.

HDR color edits first tone-map to SDR, explain that a new SDR file is required,
and always preserve the original. Geometry-only
HDR edits retain section 3.5 protections: preserve supported gain maps, otherwise
refuse replacement or tone-map a new file with the existing warning. Preview
uses the corresponding SDR rendition when conversion is required. Unsupported
preview conversions disable saving and explain the failure. All exports retain
the shared staging, validation, conflict avoidance, Trash and history Undo path.

This release excludes multitrack editing, subtitle editing, generative repair,
curves/per-color adjustment, saved custom styles and batch application. Required
verification includes real-Mac rendering and interactions, output geometry and
color, JPEG/PNG/HEIC/HDR, combined video timing and volume, cancellation, both
save modes, source protection, temporary cleanup and large-media performance.
Run build, lint and `make test-device`, followed by three fresh-context
GPT-6.1 Sol/high reviews: features/UI/spec, corrected output/safety/concurrency,
and final release candidate with physical-machine evidence. Fix reproducible
harmful findings without speculative complexity (ADR 0039).

### 8.1.2 Editor markup, frame and sound tools

**Markup** (photos and videos) offers the tools Select, Redact, Box, Arrow and
Text. Redactions use Mosaic, Blur or Solid; the inspector notes that mosaic and
blur can sometimes be partly reversed and solid cannot. Annotations use six
colours (red, yellow, green, blue, white, black) and three sizes; text is one
line of 1 to 200 characters, applied only after input-method composition is
committed. An edit holds at most 50 markup items. In the viewer, dragging
creates an item, clicking selects it, dragging moves it, rectangles have eight
resize handles that keep their screen direction under flips, rotation and
straightening, arrows have endpoint handles, and a click places text. Each tool
also has an **Add …** button for creation without a pointer. The inspector
shows positions as percentages measured on the original frame before crop and
rotation, and lists the items with Delete. Delete removes the selected item,
the arrow keys nudge it by 1% (10% with Shift) in screen directions, and Escape
deselects and then returns to Select.

Markup is stored in the oriented source canvas, before crop, rotation and
flips, in normalized top-left coordinates (ADR 0070). Redactions are rendered
into the source pixels before geometry and colour adjustments, so they stay on
the covered content after a later crop or rotation; a rectangle drawn on a
straightened image stores its bounding box, so it covers at least the dragged
area. Redaction extents round outward to whole pixels. Mosaic averages each
block before pixellating, and a region narrower than one block uses its own
area average; pixels outside the region stay unchanged at every preview scale.
Box, arrow and text are drawn after geometry and colour on the output, upright
and never mirrored, with sizes defined relative to the full-resolution output so
that preview and export match. Compare Original hides markup; the Crop tab
still shows redactions. Markup counts as a colour edit: on HDR media it forces a
new SDR file, and the editor says so before saving.

Video markup has a **Visible Range** in source time of its video: Start and End
fields, Start at Playhead and End at Playhead, and **Show for Whole Video**. New
items cover the whole source under the playhead. In the Markup tab, I and O set
the selected item's range so that it includes the frame at the playhead. Preview
and export select active items through one rule that maps the displayed source
frame, using that source's own frame rate, so a frame inside a range is covered
in both. An item survives split, reorder, duplicate and speed changes because
it follows source frames. A warning appears when the range falls outside every
segment. An overlay lane under the clips shows one bar per output range; clicking
a bar selects the item and switches to Markup.

**Save Frame** (the camera button or Shift-Command-S) exports the edited frame at
the playhead, with the export's geometry, colour, markup and fades, next to the
video in the thumbnail format from Settings, named `stem_frame_m-ss.mmm.ext`.
HDR frames are tone-mapped to SDR. It runs as its own batch while editing
continues; the output summary shows Saving Frame…, then the saved name with
Show in Finder, or the failure. It waits for pending boundary edits, and closing
the editor completes an export already planned.

**Freeze Frame** (timeline bar, segment menus, Option-F) splits at the playhead's
frame and inserts a two-second freeze as one Undo step. A freeze segment holds
one source frame with silent audio for 0.1 to 30 seconds, set in its Freeze
Duration field; it requires speed 1× and volume 0, cannot be trimmed, split or
reversed, and the inspector explains why those controls are off. Freeze clips
are cyan with a snowflake badge and have no trim handles.

**Reverse** (timeline bar, segment menus, and **Play Backward** in the
inspector's Direction section) renders the segment's source range backwards once
into a staged intermediate and then references it as an ordinary additional
source (ADR 0071). A segment can be reversed when its source range is at most
60 seconds; longer segments and freeze frames explain why not. Progress and
Cancel appear in the output summary, and timeline editing, geometry, markup,
resolution and saving wait meanwhile. Reversed clips carry a Reversed badge and
keep the source name; reversing again restores the forward range, including
trims made while reversed, without encoding again. The intermediate is HEVC at
quality 0.95 (Main10 for HDR, HEVC with Alpha for transparent sources) with
uncompressed 32-bit float audio. Decoding keeps at most 256 MiB of pixel
buffers per group of pictures in memory and spills larger groups losslessly
compressed to staging on the source volume. Before decoding, a capacity check
estimates the largest group's spill, the audio, the output at uncompressed frame
size and a container allowance, and refuses with the required and available
space; it can refuse an operation whose compressed result would have fitted.
The source frame index is limited to 4 million frames. Intermediates stay
available to session Undo until the editor closes, so repeated reversal can
retain several. An edit with a reversed segment saves through the joined path: a
new H.264 MP4, with transparency flattened and HDR converted to SDR. The editor
shows that notice before saving and disables Replace Original. Save, Save Frame
and Reverse each apply stream consent per source file (section 8.2).

**Remove Silence…** opens a popover with Silent below (−60 to −20 dB, default
−40) and Pauses longer than (0.3 to 5 seconds, default 0.75). A cancellable
analysis measures each source's sound in 20 ms windows and caches the levels,
bound to the source's identity stamp, until the editor closes; a changed source
requires reopening. The popover reports "Removes N pauses (m:ss.s)", the
timeline hatches the ranges in red, and **Apply** cuts them as one Undo step.
Each cut keeps 0.12 seconds of sound on both sides. Pieces inherit their
segment's settings with new identities, only the outer pieces keep fades,
pieces shorter than two frames are dropped, and freeze and muted segments are
skipped. The popover explains when the video has no audible sound or when
nothing would remain. Escape and Return act on the open popover first.

**Background music** (Add Music…, Replace Music…) accepts MP3, AAC/M4A, WAV,
AIFF, CAF, FLAC, Ogg and Opus. One song plays once from output time 0 at a
chosen start position in the song and volume (default 30%), under the video's
own sound. When it outlasts the video it is cut at the end with a one-second
linear fade-out; a shorter song is followed by silence. A music lane under the
clips shows its length and fade, and a Background Music section in the
inspector holds volume, Start in Song, Replace and Remove, each one Undo step.
Export mixes the song at 48 kHz stereo and clamps the sum to full scale; it adds
an audio track when the video has none or every segment is muted. Preview mixes
natively without rendering the timeline first; songs that AVFoundation cannot
play directly, such as Ogg and Opus, use one cached PCM copy per file until the
editor closes. Preview can exceed full scale where the output device clips, so clipping material can sound different from
the export. The song is never written. Its identity stamp is checked when
saving starts and after export; a changed song stops the save with an
explanation.

### 8.2 Videos

The Edit Video panel defaults to the complete range, 1×, original resolution.
It previews output dimensions, duration and the current save policy. Cuts are
exact. Native
containers play directly through AVPlayer. Other supported containers use a
cancellable, low-resolution temporary playback copy; export reads the original. Playback speed also accepts arbitrary finite values from 0.5 to 4.
Speed changes use a common source/output timeline for video and audio. Slower
video repeats frames, without interpolation. AVAudioUnitTimePitch preserves
pitch through bounded offline PCM rendering; disk staging avoids retaining a
whole recording in memory. Audio offsets, gaps and tails retain their timeline.
For native MOV/MP4/M4V speed outputs, the final AVAssetWriter accepts PCM and
encodes AAC itself, preserving a standard priming edit list across players.
Its bitrate uses the existing sample-rate/channel-specific supported values.
WebM/MKV use Opus; AVI uses PCM, and FLV uses 44.1 kHz 16-bit little-endian PCM.
Playback-speed audio currently supports mono and stereo. Unsupported channel
layouts fail before output instead of silently downmixing.
Pitch error must stay within 1%; A/V synchronization error at the beginning,
middle and end must stay within the greater of one video frame and 20 ms.
All edits use the existing staging, validation, collision, Trash and Undo paths,
including HDR, transparency and metadata protection.

Containers: MP4, M4V, MOV through AVFoundation; MKV, WebM, AVI, FLV through
the in-house demuxers. Video codecs: H.264, HEVC, ProRes, MPEG-4 Part 2 and
MJPEG through VideoToolbox; VP8 and VP9 through libvpx; AV1 through VideoToolbox
when `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)` is true, otherwise
dav1d. Audio codecs: AAC, MP3, PCM, ALAC, AC-3 through AudioToolbox; Opus and
Vorbis through libopus and libvorbis; FLAC through AudioToolbox. Inputs the
native engine cannot decode, such as WMV, ASF, MPEG program and transport
streams, VOB, RealMedia, MXF, DV, 3GP, Ogg video, or DTS, E-AC-3, WMA and other
audio inside a supported container, are decoded through the staged fallback of
section 25.3, and their results are always saved as new files. The native
error, naming the codec, is kept when the fallback cannot decode the file
either.

Transform operations in either output mode refuse inputs with more than one
video track or more than one audio track before writing an output, because the
pipeline selects the first track of each kind. Explicit exports such as
thumbnails, animation, and audio extraction select the required tracks and
report omitted streams. A new-file Transform is not permission to drop streams.

Content the pipeline cannot carry over is never dropped without the user's
consent (ADR 0075). The kinds are timecode, subtitles, closed captions,
chapters, attachments, timed metadata, extra audio, extra video and other data.
Before encoding, a transform inspects the input and stops the item with
`unpreservedStreams`, naming every kind it would leave out; nothing is written.
Activity presents this as a question (section 6), the video editor and Add
Videos… ask in a sheet before opening, and Audio Trim, Finishing Recipes and
Audio Enhancement ask before running. Consent is recorded per file as the file
stamp taken before inspection (size, modification date and identity) together
with the kinds that file reported. It is applied only while the file still
matches that stamp: if the file is replaced while a sheet is open, approving
inspects the new file and asks again, and a run whose input changed fails as
changed without touching the new file. Consent for one file never covers
another, and consent for other data never authorizes discarding another audio
stream. A result whose content was left out carries the note **Left out, as you
confirmed: {kinds}.** Where no question can be asked, the failure names the
file and the content and says that nothing was changed. Removing audio only
permits the requested audio omission.
Explicit Derived exports report other stream omissions while keeping the
original. No frame, stream, metadata, alpha, or channel loss is silent.

Settings > General > **If some content can’t be kept** defaults to **Ask**
(ADR 0086). **Save without it** is carried on the operation request, or on
the Finishing Recipe batch request, and enforced by the engine before encoding against the
item's actual commit disposition: an item whose result is saved as a new file
continues once without the reported kinds, keeping its ordinary warnings, a
`streamsOmitted` note, history, Undo and notification; a real replacement
always asks. Continuation checks the identity-bearing input stamps again, and
an input that changed stops as changed without running again. A refusal after
encoding has begun is not continued automatically. Finishing Recipes always
derive and pass the same policy to their engine batch. The editor's open and
Add Videos… sheets, Trim and Enhance keep their own questions. Settings saved
before this choice existed decode as Ask, and Reset All restores Ask.

MOV outputs of timing-preserving operations carry an AVFoundation-readable
timecode track natively in the same AVAssetWriter session as the video; no
FFmpeg remux, atom transplant or regeneration is involved. All real samples are
validated before encoding; payload, format description, sample count, frame
duration and quanta, flags, presentation and decode times, durations, track
association to the video, enabled state, language and metadata are preserved
exactly, and zero-sample markers are skipped. The writer uses the least common
multiple of the movie and timecode time scales; when the source movie duration
was rounded, the track duration may differ by strictly less than one source
movie tick while every real sample still matches. An empty timecode track, a
malformed sample, several format descriptions, an unsupported or clipped edit,
or a time scale that cannot be represented falls back to the consent question
before encoding. The output is verified against the original after encoding;
the rare mismatch found then also falls back to the consent question, in
Activity and in Finishing Recipes, which rerun with the merged consent bound to
the unchanged source stamps. Writer, read, file-system and source-change
failures keep their own errors. MP4, M4V and other containers,
timing-changing operations and target sizes that allow frame-rate reduction ask
for consent instead. A file whose timecode the user already agreed to leave out
is never carried again. Timecode plus subtitles asks only about the subtitles
when the timecode can be carried. Subtitles, chapters, attachments and other
kinds, including those in MKV, are not carried.

Every AVFoundation entry point in the engine and the app opens media through
one constructor that sets `AVURLAssetReferenceRestrictionsKey` to
`forbidAll`, and `AVAudioFile` entry points first reject files with external
references (ADR 0077). A QuickTime reference movie that points to media in
other files therefore fails in conversion, compression, the editor,
thumbnails, animation export, Audio Trim, archive browsing and Finder Preview
with "This file refers to media in another file, so MacEase can't open it.
Export a self-contained copy in the app that made it." Errors other than a
forbidden reference are reported as themselves.

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
track-targeted tags and TrackEntry Name count as track metadata. Muxer
ENCODER, ENCODER_SETTINGS, DURATION and statistics tags (BPS,
NUMBER_OF_FRAMES, NUMBER_OF_BYTES, _STATISTICS_*) are provenance, not user
metadata.
TrackEntry LanguageBCP47 takes precedence over legacy Language regardless of
element order. Unsupported track names and languages use the same loss checks.
TrackEntry FlagEnabled defaults to enabled when absent. Matroska/WebM outputs
retain it, and native outputs map it to the existing enabled-track setting.
Destinations without enabled-state storage use the enabled-state loss warning
for new files and Derived exports, and refuse Replace before staging. Output
verification detects changed enabled states in both native and Matroska/WebM
containers.
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
Matroska laces retain contiguous timing from DefaultDuration or known codec
sample counts. BlockDuration is a fallback divided only among equal-sized
laces, never copied whole onto each packet. Unresolved later laces carry an
explicit continuation marker and never prevent demuxing unused tracks.
PCM copies and decoded audio advance continuations by their sample counts
without inserting silence or dropping overlaps. Matroska/WebM copies retain
unresolved laces in a single block. Copy paths requiring individual packet
timestamps refuse unresolved selected tracks during packet consumption with
the existing unsupported-codec error; raw elementary-stream copies remain
available.
Signed DiscardPadding trims from the start or end of the whole Block. Known
lace durations distribute that trim from the corresponding end. Unresolved
laces retain group padding through remuxing; decoding applies it to the whole
decoded group with a 250 MB buffer limit. PCM copies and re-encodes retain the
same valid sample range and presentation timing.
AVI/FLV and raw elementary audio copies refuse padding, except trailing padding
of CodecDelay audio, which section 13 leaves unsignalled. Ogg copies support
only positive padding on the final packet; native packet copies refuse
negative padding.
Other padded copies use the existing unsupported-codec error during packet
consumption, leaving re-encoding available.
Unsplit BlockDuration remains attached to its lace group. Timed video edits
also refuse unresolved video timing. Range copies may retain whole unresolved
groups but refuse cuts through them during packet consumption; excluded groups
do not prevent a trim. These input limitations discard staging, leave the
original untouched, and produce no output. Policy preparation does not scan
packets for unresolved timing. Incomplete output lace groups retain at most
250 MB of payload.

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `video.resize` | 50%, 2160p, 1080p, 720p, 480p, 360p | Transform | Re-encodes video with the source codec family when it is H.264 or HEVC, otherwise the settings codec; audio is copied |
| `video.edit` | — (editor) | Transform | One video: time range, speed, resolution, geometry, color, style and volume in one export. Unchanged input disables Save. Segments support split, delete, duplicate, reorder and individual speed, volume and color; cuts are exact. HDR color edits always derive SDR. Section 8.1.1. |
| `video.speed` | 0.5, 0.75, 1.25, 1.5, 2, 4×, Custom Speed… | Transform | Multiple videos; finite custom values from 0.5 through 4, including fractional values. Preserve audio pitch. |
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
| `video.extractAudio` | Original, MP3, M4A (AAC), M4A (ALAC), AAC, WAV, AIFF, FLAC, OGG, Opus | Derived | Copies the stream when the target holds the source codec, else encodes; Original ignores bitrate preferences and refuses unsupported timing; explicit formats copy with Automatic bitrate when possible, otherwise encode |
| `video.subtitles` | SRT, VTT, TXT, Translated SRT | Derived | Speech framework `SpeechAnalyzer` with `SpeechTranscriber` and audio time ranges; language from settings or the system locale; cues split at sentence boundaries, at most 42 characters per line and 2 lines; translation with the Translation framework |
| `video.background` | Remove, Green Screen, Blue Screen, Custom Color, Blur | Derived | Section 8.11 |

Over-limit compression opens the video editor with a preselected range and
compresses its successful outputs through `video.edit`. Historical `video.trim`
batch records decode as `video.edit` without changing their commit records, so
Undo remains available. Internal trimming used by VideoEdits is retained.

### 8.3 Audio

| ID | Presets | Mode | Behavior and acceptance |
| --- | --- | --- | --- |
| `audio.convert` | MP3, M4A (AAC), M4A (ALAC), AAC, WAV, AIFF, FLAC, OGG, Opus, CAF (PCM), CAF (ALAC) | Transform | Bitrates from settings; tags (title, artist, album, artwork) copied where the target supports them |
| `audio.compress` | 64, 96, 128, 192 kbps | Transform | Re-encodes in the same lossy format, or AAC in M4A for lossless sources and for MP3 below 128 kbps (ADR 0010) |
| `audio.normalize` | −14 LUFS, −16 LUFS, −23 LUFS | Transform | ITU-R BS.1770-4 integrated loudness; gain only, capped so the 4× oversampled true peak stays at or below −1 dBTP; the notification reports when the cap stopped short of the target |
| `audio.trim` | — (panel) | Transform | Sample-accurate for PCM and lossless; frame-accurate re-encode for lossy; optional linear fade in/out within the kept range |
| `audio.subtitles` | SRT, VTT, TXT, Translated SRT | Derived | Same on-device transcription, translation, settings, and cue rules as video subtitles; no video track required |

Inputs: MP3, AAC, M4A, ALAC, WAV, AIFF/AIFF-C, CAF, FLAC, Ogg Vorbis, Opus
natively; WMA, AC-3, DTS, MP2, WavPack, Monkey's Audio, TTA, AMR, RealAudio,
MKA and other audio the native engine cannot decode through the staged
fallback of section 25.3, whose results are always saved as new files.
WAV input includes RF64 and BW64. Their mandatory first `ds64` chunk supplies
64-bit RIFF and audio lengths and optional oversized-chunk lengths. Chunk
ranges are checked against those lengths and the file before replacement.
The optional size table is capped at 4,096 entries before accumulation.
AVAudioFile supplies native decoding (ADR 0010).
Audio Transform in either output mode stops before writing for extra streams
or chapters that its output cannot preserve and asks for consent as in section
8.2 (ADR 0075). WAV cue and other ancillary chunks, ID3 and FLAC chapters,
synchronized lyrics, encapsulated objects and timing or private payloads, and
the additional streams of a multiplexed Ogg file are asked about. Consented ID3
frames are not refused again as unsupported tags; unrelated unsupported tags
keep the protection below. After consent, Audio Trim, Audio Enhancement and
waveform reading use the first stream of a multiplexed Ogg file.

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

Opus decoding in Ogg, Matroska and WebM applies the OpusHead output gain.
Matroska and WebM use CodecDelay alone for pre-skip. Decoding other Matroska and
WebM audio also drops CodecDelay at the stream start (ADR 0056). Matroska
HE-AAC currently decodes at its SamplingFrequency core rate, and HE-AAC v2
from Matroska fails to decode.

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
| `archive.extract` | — | Derived | The Finder menu is RAR-only; legacy internal requests retain their existing decoder coverage. RAR (read only) uses libarchive into a fresh collision-safe folder named after the archive stem, including when the archive has a single top-level folder; extraction flags `SECURE_NODOTDOT` and `SECURE_SYMLINKS`, absolute and `..` entry names refused before writing, `__MACOSX` skipped, quarantine copied from the archive, output capped at the larger of 1 GiB and 1000× the archive (ADR 0010); encrypted entries open the Password panel |
| `archive.browse` | — | Report / Derived export | One ZIP; hierarchical listing, name/path search, selected-file preview and explicit selective save; section 8.14 |

Ordinary extraction and archive output verification enable the ZIP, TAR, 7z,
RAR and RAR5 formats explicitly, plus raw streams after a supported filter for
single compressed files. Unfiltered raw input, plain text and images are
refused as "This file isn’t a supported archive or compressed file." LZ4,
LZOP, LRZIP and GRZIP signatures are refused rather than published as a raw
payload. TAR with zstd remains readable. A ZIP inside another compression
layer is refused with "ZIP archives wrapped in another compression format
can’t be extracted. Decompress the outer layer first." These rules do not
change Finder menu eligibility.

**Entry names.** UTF-8 always wins: libarchive's UTF-8 pathname, a ZIP Unicode
path field whose CRC matches, and raw bytes that are valid UTF-8, even when
they are also valid CP932. Other names are decoded by one archive-wide choice
(ADR 0083). When any of the user's preferred languages has the language code
`ja` (region or script subtags allowed, not necessarily first; `en-JP` does
not count), names are decoded as Windows CP932 if every non-UTF-8 name in the
archive passes a strict check: valid lead and trail bytes, an assigned code
point, Foundation's decoding, and no private-use characters or controls other
than tab, line feed and carriage return. Otherwise ZIP decodes every non-UTF-8
name as CP437, never mixing the two; TAR refuses non-UTF-8 names with "This
archive uses a text encoding for file names that MacEase can’t read.", so
different names cannot collapse into the same replacement-character name.
Windows-1252, Latin-1, EUC-JP and other encodings are never guessed. Link
targets use the same choice. The language preference is read once at each
operation, reader or browser-session boundary and passed down; a Browse
Contents session keeps its choice for listing, preview and export. ZIP
extraction checks every name before writing anything; TAR, 7z and RAR decode
per entry, and any failure discards the staged output. ZIP name fields are
checked for embedded NUL before conversion. Path checks are unchanged:
absolute and parent-traversing names are refused, and the extractor applies
no extra Unicode normalization.

**HatchZip extraction.** `archive.hatchExtract` appears as **Extract with HatchZip**
for ZIP, 7z, TAR, tar.gz/tgz and recognized
`.zip.NNN`, `.7z.NNN`, `.tar.gz.NNN` volumes. Bare numeric extensions are not
classified as archives. The host normalizes and deduplicates selected volumes;
the helper checks each complete set and
its contents before mutation; non-first volumes need not contain a format header.
The ordinary extraction menu is absent for these and standard gzip/bzip2/xz files.
ZIP Browse Contents remains independent and non-destructive.

The app bundles a pinned Rust helper using `hatchzip-core`, with UnRAR disabled.
Requests and events use structured local pipes; archive passwords are not stored
or placed in arguments/logs. Extraction starts immediately without confirmation
or an original-preserving option, except for the legacy-name route below.
Preflight verifies the complete archive, free
space, archive paths, expansion limits and all volumes before destructive work.
Hard-linked inputs, unsupported File Provider/network locations and untrusted
recovery records fail before mutation. Existing outputs are never replaced.

Private durable sessions preserve archive/output identities, captured quarantine,
and checkpoints. Quarantine must reach each output before its source bytes are
released. Pausing or crashing preserves the sole remaining copies; Activity and
app relaunch expose Resume. Resume only trusts MacEase-owned session records.
History cleanup does not remove incomplete sessions, and completed extractions
have no Undo action. Upstream restore is not presented as original-file recovery.
The source and output stay on the same volume; snapshot-held blocks and
unsupported hole punching may limit actual reclaimed space.

**Legacy-name route.** A new HatchZip request first inspects every name: ZIP
reads the central directory and bounded link payloads, never file bodies; TAR
reads every header, inflating gzip as it goes. Inspection is limited to
100,000 entries, 32 MiB of name, extra-field and comment bytes, path depth 256,
link payloads of 64 KiB, the extraction expansion limit and 10 seconds, with
cancellation; exceeding a limit refuses with "MacEase couldn’t verify this
archive’s file-name encoding within the inspection limits. The original was
not changed." When the archive-wide choice above selects CP932, the native
extractor runs instead of the helper: staged extraction, the collision-safe
Derived commit, quarantine, verification and history, keeping the archive in
both save modes with Undo removing only the output. Regular encrypted ZIPs
(ZipCrypto, WinZip AES-128, -192 and -256) use the typed password, ZIP64 has
no separate size cutoff, and the expansion limit of section 8.5 applies.
Activity shows Stop, which cancels and removes staging, rather than Pause.
Split volumes, unsupported ZIP compression methods (including Deflate64),
strong encryption, backslash separators, encrypted ZIP links and link
compression other than stored, deflate or LZMA refuse before any change with
"This archive uses legacy file-name encoding and an unsupported extraction
feature: …. The original was not changed." All other archives, including
CP437 ZIPs, keep the helper route and its in-place behaviour. TAR whose names
are neither UTF-8 nor accepted CP932 refuses before any change. Before
starting the helper, a new session saves a private versioned proof of the
inspected input, the language snapshot and the route. A paused session
resumes on the route it started with, without inspection, whether or not it
has a proof and even if the preferred languages changed, so partly consumed
input stays reachable and names do not change partway. The helper itself is
unchanged.

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

File formatting uses a shared strict scanner and bounded UTF-8 chunks.
Pretty Print and Minify write directly to staged output. Sort Keys stores
value spans and container records in private temporary files, sorts bounded
reference batches, and merges them on disk. The existing depth limit, numeric
lexemes, duplicate members and ordering semantics remain unchanged. Temporary
files are removed on completion or failure. Case-insensitive comparison and
pin matching fold scalar-aligned chunks to disk. Natural comparison uses
file-backed UTF-16 spans and pinned ICU collation with bounded caches,
preserving Foundation's existing comparison shell and scalar tie-breaking.
Collation elements, numeric runs and canonical-ordering state spill to private
temporary files rather than retaining complete keys (ADR 0032).
Long common combining prefixes use content-based ordering. Foundation can
return inconsistent results for identical text in different internal string
representations; those unstable results are not an ordering contract. The
bounded comparator agrees with Foundation given complete UTF-16 storage.

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
- **PNG.** For a static 8-bit RGB image, first try bounded balanced lossless
  compression, then a balanced 256-color candidate at the original dimensions.
  If it exceeds the target and downscaling is allowed, retain 256 colors and
  estimate a smaller area from the measured payload size after subtracting
  fixed PNG overhead, with 5% headroom in the target.
  Correct from each measured result for at most three scaled attempts. Balance
  natural colors, useful resolution and latency rather than exhausting maximum
  compression and severe palette reductions at every resolution (ADR 0049).
  Check candidate fidelity in uniformly spaced native-resolution windows before
  accepting palette reduction: mean luma SSIM must reach 0.97 on both black
  and white composites, and each window's mean Oklab chroma error must not
  exceed 0.02. Inspect at most 8 × 8 Gaussian 11 × 11 windows without another
  full-frame decode. An inadequate palette switches that item to balanced
  lossless RGB/RGBA at the current and subsequent scales, using the same
  measured-size rule and correction bound. Preserve color and alpha rather
  than accepting visible hue patches; report the actual palette/dimension
  changes. Existing independent full-image quality tests remain unchanged.
  When downscaling is forbidden, keep the original dimensions and retain the
  existing bounded 256-, 128- and 64-color search, including strong compression
  fallback and the same palette quality checks. A target whose palette fails
  those checks fails explicitly. Do not duplicate that search with oversized
  planning probes. Non-target PNG presets use balanced native effort with
  unchanged selected palettes and decoded pixels; encoded size can increase
  slightly, subject to the existing output-not-smaller check.
  Greater precision, HDR,
  non-RGB color spaces and animation retain their existing preservation paths.
  Conversion remains balanced lossless, without palette reduction; standalone
  optimization retains its never-larger contract. Measure oversized planning
  candidates within the existing working and encoded-output limits, release
  each before the next scale, and accept only verified outputs within the exact
  requested byte limit. Bounded exhaustion reports target failure without
  repeating the search solely for a minimum-size estimate. Share exact pixels
  where supported and derive factual reduction reports from accepted results.
  PNG filter, palette and compressed workspaces use scoped mappings; output
  views retain their complete owners until release.
- **GIF.** Reduce fps, then width, then colors.
- **Video.** A generic byte target already met by the source skips without
  encoding. Platform presets still enforce their format and geometry limits.
  Otherwise plan in order and stop at the first output under target:
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
- An item that cannot reach the target fails and keeps the original. Report
  the smallest measured candidate when available; exhausted bounded static-PNG
  searches instead explain that the current settings did not reach the target
  and suggest increasing it, without claiming an unmeasured minimum.
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
codec works. The host validates actual codecs before writing. No Windows
component or unapproved dependency is introduced to fill a pair. The bundled
FFmpeg CLI only decodes inputs into a verified intermediate (section 25.3); it
never writes a user's output.

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
in sections 3.5 and 8.3. WMA and the other fallback-decoded formats of
section 8.3 are inputs only, never targets, and always produce new files.

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

### 8.14 SVG comparison and ZIP browsing

These Finder actions open ordinary resizable windows at normal level. They
are result and essential-input windows, not a main document workflow. Each
window owns its tasks and temporary content independently. English and Japanese,
keyboard navigation and system appearance settings are supported.

**Trace to SVG.** The menu requires one PNG by extension; the host verifies
actual static PNG content and refuses animation. Existing Convert > SVG and
its settings retain their behavior. The dedicated action always traces and
always saves a Derived file, regardless of the global SVG or output mode.
Source and SVG share the same display scale. Colors range from 1 to 8, starting
at the saved SVG color count. Detail starts at Standard. Less uses 1.5 times
the standard simplification and curve-fitting tolerances; Fine uses half and
keeps contours below the standard three-pixel area cutoff. Standard retains
the existing 0.8 simplification and 0.6 fitting tolerances.

Preparation runs off the main actor, supports cancellation, and publishes only
the latest settings revision. Save remains unavailable during preparation and
writes the exact complete SVG shown in the comparison. Output uses filled paths,
not an embedded PNG. Image memory limits and the existing alpha, HDR and metadata
policies still apply; warnings appear before saving. The original is retained.
The source's identity, size and modification date are checked again during the
coordinated export commit. A changed source produces no new output.

**Browse Contents.** The menu requires one ZIP. A seekable libarchive reader
lists central-directory metadata without expanding all members. A cancellable
preflight counts actual central records before libarchive allocates its index.
Listing is limited to 100,000 entries, 32 MiB of names, extra fields and comments,
and 256 path components. End-of-central-directory search covers the largest
65,535-byte comment; a valid comment of that size is read through a logical
view ending after the end record. Entry names are decoded as in section 8.5
and displayed through the inert-text rule of the Finder Preview archive list
(section 25.1). The hierarchy also limits retained paths to 32 MiB.
Empty ZIPs are valid. Hierarchical rows distinguish duplicate paths by stable entry identifiers.
AppleDouble members remain visible and are not implicitly expanded.
Search uses names and paths without opening member contents.

Only selected regular files are materialized for preview, at most 256 MiB per
file, within managed private local staging even when the archive is read-only.
Images, PDFs, audio and video use native viewers; text is read-only. HTML and
scripts are displayed as text, never executed. Text previews may show a clearly
labelled bounded prefix. Unsupported formats show file information and Save.
Passwords remain in window memory only. There is no external-application launch.

Absolute or parent-traversing paths, links and special files are refused.
Declared sizes, actual expanded bytes and CRCs are checked before preview or
export. Selective export uses the existing expansion limit. Source identity,
size and modification checks prevent reusing an index for a changed archive.
Resource-limit failures are explicit; entries are not silently omitted.

A single-file save selects its name with a save panel. Multiple files or a
folder select a destination directory and create `archive-stem_selected`,
retaining the selected hierarchy. Overlapping selections are deduplicated;
duplicate directory records share one exported directory; conflicting file paths
never overwrite each other. A selective export scans the archive once for all
selected files. Empty members and folders
remain valid outputs after successful archive decoding. Exports preserve
quarantine and use the existing collision-safe, verified, undoable Derived
commit path. Saved files outlive their browsing window.

Closing stops readers and renderers, waits for writers, and removes owned
temporary files. Closed sessions cannot create more content. Failed removals
remain registered for retry, including at the next host launch after a crash.
Normal application quit also closes these sessions before termination.

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
**Set Up MacEase**, one sentence describing the Finder workflow, and a
static MacEase screenshot of Resize > 50%, with descriptive alternative text.
No Flect tagline, illustration, or asset is reused.

The Welcome window also offers Add Folder… using the same folder picker as Settings.
The checklist contains Finder extension status with Turn On…, Notifications
with Allow, and Open at login with its default-on switch. A short note explains
first-use protected-folder prompts for Desktop, Documents, Downloads, removable,
and network volumes, plus a Full Disk Access shortcut. Status refreshes when
the app activates. Done permits incomplete permission rows.

If translocated or outside `/Applications` and `~/Applications`, the checklist
is replaced by Move MacEase to Applications guidance and Quit MacEase. Done is
disabled until relocation. The regular window has no pages, dots, or step
animation. It supports keyboard navigation, native state labels, larger text, and
Reduce Motion.

After Done, if Finder Sync remains disabled, the menu bar shows Turn On Finder
Extension… until it is enabled, and the status item shows its attention badge
until the menu is opened. Settings > General > Show Welcome Window…
reopens this window.

A normal launch without an operation, reopening the running app from Finder,
Spotlight or Dock, and `macease://open` all show Welcome if onboarding is
incomplete, otherwise Settings. `applicationShouldHandleReopen` uses the same
routing. A Finder run request routes directly to its operation and essential
panel or Activity, without opening Settings as a side effect. The extension's
Open MacEase fallback follows the same open route.

## 12. Updates

When **Check for updates automatically** in Settings > General is on (the
default), the host requests
`https://api.github.com/repos/TKY-27/MacEase/releases/latest` at launch and at
most once every 24 hours. With it off, no automatic request is made (ADR 0081).
**Check for Updates** in the menu bar always requests, ignoring both the switch
and the interval. A version found earlier stays available until a later check
clears it. When the tag is
newer than the running version (semantic versioning), it shows a notification,
a first menu bar item and a first item inside the Finder MacEase submenu.
All three open the same single Update window through the existing window
presenter. The compact native window is approximately 460 points wide, with no
decorative cards. It shows the available and running versions, **Download from
Official Site**, **Later** to close, and **How to update** with these steps:

1. Quit MacEase from the menu bar.
2. Move the old MacEase in Applications to the Trash.
3. Open the downloaded file and drag MacEase into Applications.
4. Open MacEase.
5. Turn on MacEase again in System Settings > General > Login Items & Extensions
   > Finder, and allow folder and privacy access again when macOS asks.

**Open Extension Settings** uses Finder Sync's extension management interface.
The download button opens the official website. Japanese UI opens
`https://macease-site.pages.dev/ja/#download`; other UI languages open
`https://macease-site.pages.dev/#download`. Stored release-page URLs are migrated
to this destination. Clearing update availability closes the Update window. No app
update is downloaded or installed automatically. A confirmed available version
is notified again after 24 hours while notifications are enabled, including
after app relaunch; a newer version notifies immediately. Manual checks do not
repeat a notification within that interval. Network errors are logged and
ignored until the next check.

## 13. Error handling

- Input validation accepts only regular files and directories after resolving
  symlinks. Special filesystem entries are rejected before content reads,
  including panel previews.
- Errors are typed per domain (decode, encode, commit, unsupported codec,
  permission, cancelled, target unreachable, invalid input). Each maps to a
  localized, single-line failure headline naming the action and file, explaining
  the cause and suggesting a next step. Cancellation remains neutral. Decode,
  encode, commit, unexpected-error, unsupported-codec and malformed-input strings are
  available through Activity's Details disclosure, separate from the headline
  and notifications. Empty diagnostics do not show an empty disclosure.
- Successful operations with ItemWarnings remain successes. Concise notes explain
  format limits or other output differences without suggesting failure. Omit
  routine original-retention boilerplate; retain meaningful exceptions such as
  a requested replacement becoming a new file because Trash is unavailable.
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
  SeekPreRoll. Other native audio copied into Matroska or WebM keeps its
  priming packets: the leading trim becomes CodecDelay and trailing trim becomes
  DiscardPadding. Later leading trims keep whole packets as below. AAC tracks
  store the AudioSpecificConfig core rate as SamplingFrequency and a
  differing SBR rate as OutputSamplingFrequency. Copied audio in AVI and FLV, and
  Matroska CodecDelay audio copied into AVI, FLV or extracted audio, uses whole
  packets on the edited presentation timeline, starting at or after the trim
  origin without negative timestamps or trailing padding. Its start may differ
  by up to one audio frame. Native copies of Matroska CodecDelay audio keep every
  packet and currently play the priming, because AVAssetWriter ignores trims on
  container packets. Rate-changing audio edits fail with an unsupported-timing
  error before their packets are appended (ADRs 0023, 0024 and 0056).
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
  of explicit allocations, not a substitute for the full-app memory acceptance
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
- Media is opened with external references forbidden (section 8.2).
- Finder Preview treats files carrying `com.apple.quarantine` as restricted and
  renders HTML statically and offline unless the user grants a file version
  network access or trusts its folder (section 25.1).
- Automatic update checks can be turned off (section 12).
- No analytics, no crash reporting service. Logs stay local.
- The menu file and history are mode 0600.

## 15. Localization

- String Catalogs for English (development language) and Japanese in the app and
  the extension.
- The host writes localized menu titles into the menu file in its own UI
  language, so the Finder menu always matches the app's language setting.
- Formats and units use the current locale; file sizes use `ByteCountFormatter`
  with decimal units.
- Every catalog key has a Japanese value with the same placeholders, and every
  `NS…UsageDescription` of the app and its extensions has English and
  Japanese; an app-hosted test enforces both. Japanese uses one term per
  concept, no space between Latin and Japanese text, full-width parentheses
  and `：` before a reason, and 取り消す for Undo (元に戻す remains Revert).

## 16. Non-functional requirements

| Requirement | Target | Verification |
| --- | --- | --- |
| Menu build time | `menu(for:)` ≤ 30 ms for 1,000 selected items | Unit benchmark of the menu model plus manual check |
| Request transport | 5,000 paths in one request | Automated host test of URL parsing; manual end-to-end check |
| Image conversion | 12 MP HEIC to JPEG ≤ 0.5 s on M1 | `scripts/bench.sh`, manual |
| Video compression | 60 s 1080p30 H.264 15 Mbps with AAC to 20 MB ≤ 30 s on M1 | `scripts/bench.sh`, manual |
| Memory | Peak resident memory ≤ 1.5 GB for any single item except 8K video | Actual Release app: Instruments or Darwin kernel resident high-water mark |
| Large batches | 1,000 images processed without UI stalls; menu bar stays responsive | Manual |
| Idle | Host idle CPU ≈ 0%, resident memory ≤ 80 MB | Manual |

For v1.0.0, the owner approved the available Apple M5 Mac running macOS 27
as the physical acceptance machine. M1 performance and macOS 26 physical-Mac
results are not claimed. The numerical targets remain unchanged; macOS 26
checks use the available VM where applicable (ADR 0030).

When Instruments cannot record, `/usr/bin/time -l` may measure the actual
Release host from launch through verified commit and process exit. Its
`maximum resident set size` is the kernel high-water mark, in bytes. Report
peak physical footprint separately; sampled RSS alone can miss peaks.
Neither a standalone converter nor finite fixtures prove an arbitrary-input
memory bound (ADR 0031).

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
The JSON result from that run predates the streaming scanner: its 200 MB
record fixture peaked at 917 MB RSS while retaining the input and value tree.

The 2026-10-23 implementation streams Pretty Print and Minify and uses
file-backed indexes for Sort Keys. The bounded natural comparator also keeps
complete keys and collation state on disk (ADR 0032). Actual Release-app kernel
measurements cover a 200 MB dense array, 200 MB secondary-weight, combining-mark
and non-ASCII numeric keys, and 3.2 GB random keys. Peak RSS is 129–140 MB;
peak physical footprint is 73–77 MB. Every output passes an independent byte
check and every source remains unchanged. The comparator has a fixed page
budget independent of key length; finite measurements alone do not establish
that bound. Earlier whole-key results remain historical evidence in
`docs/spikes.md`, alongside measurement limits and release acceptance records.

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
- App-hosted tests run in English (`test.language: en`, region US in
  `project.yml`), so message tests assert literal English; Japanese strings are
  asserted through the `ja.lproj` catalog.
- Target-direction acceptance covers schema-4 grouping after pruning, per-leaf
  visibility and migration, stale catalogs after value edits, mixed-kind counts,
  single-input limits, every scheduled conversion pair, and explicit deferred
  capabilities. Menu presence alone does not prove a conversion works.
- Real-Mac acceptance exercises Finder invocation, retained panels, Activity's
  0.8-second delay and focus behavior, notification deduplication, Settings,
  Welcome/reopen/open routing, larger text, light/dark appearance,
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
  For v1.0.0, macOS 26 VM results supplement the approved macOS 27 physical
  acceptance machine; unavailable physical hardware alone does not block
  publication. Failed checks remain release blockers (ADR 0030).
- For v1.1.0 through v1.4.0, the owner excludes actual VoiceOver operation and the final
  macOS 26 VM visual smoke test from mandatory acceptance because they are
  unavailable in the owner's environment. Both remain unverified, not passed.
  Existing physical-machine checks and earlier VM results remain evidence;
  all other required checks remain publication gates (ADRs 0036, 0038 and 0042).

## 18. Build, CI, signing and release

- `make bootstrap` installs XcodeGen, CMake, Meson, Ninja, pkg-config and Rust/Cargo with
  Homebrew, runs `scripts/build-deps.sh`, and generates the Xcode project.
- **CI (`.github/workflows/ci.yml`)** on pushes and pull requests to `main`:
  - `lint` on `macos-26`: `swift format lint --strict --recursive`.
  - `build-26` on `macos-26` with the newest installed Xcode 26: build native
    dependencies and bundled runtimes with `make bootstrap` (cached by their pins and build scripts),
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
- **Hardened Runtime.** Enable it for the host, extension and every bundled
  Mach-O in Debug and Release (ADR 0069). Only the host receives the Apple
  Events entitlement for Finder Automation. In normal Debug and Release builds,
  only Python, FFmpeg, ffprobe and
  the two sherpa audio executables disable library validation, because the
  configured identities have no Apple Team ID. No bundled process allows JIT memory.
  The host and extension retain library validation. No unsigned-executable-memory
  or DYLD-environment exception is granted. Nested code is signed before its
  enclosing bundles; packaging verifies runtime flags and strict signatures.
  The host remains unsandboxed; the Finder extension remains sandboxed.
  App-hosted tests use an isolated `DebugTests` configuration with its own bundle
  ID and support folder. Only that test host disables library validation to
  load unteamed XCTest/package bundles; normal Debug and Release do not.
  Exception measurements use ad-hoc signatures. Equal behavior with the
  self-signed release identity is inferred from its absent Apple Team ID;
  that identity was not used in the recorded validation.
- **Release (`.github/workflows/release.yml`)** on tags `v*` on the `xcode-27`
  image: build native dependencies, regenerate third-party notices, archive
  Release, sign the helper, app and
  extension (extension with its sandbox entitlements) with the release identity,
  build `MacEase-<version>.dmg` with an Applications symlink and the install
  window below via `scripts/make-dmg.sh`, sign and verify the DMG container with
  the same identity,
  compute SHA-256, create the GitHub Release with the DMG
  and checksum, and use the matching CHANGELOG section as release notes. The
  workflow fails when the signing secrets are missing.
- For v1.1.0 through v1.4.0, GitHub Actions remains disabled by owner instruction. Build the
  signed DMG locally from the tag commit and publish it with its SHA-256 and
  release notes. Verify anonymous downloads and `releases/latest`; do not
  report the local checks as successful GitHub Actions runs (ADRs 0036 and 0037).
- **Install window.** `make dmg` builds a writable HFS+ image, attaches it
  with `-nobrowse`, writes the window layout with
  `swift scripts/make-dmg-window.swift layout <volume>`, detaches it and
  converts it to ULMO. The layout is a `.DS_Store` written directly, with no
  Finder scripting, so packaging needs no Automation consent (ADR 0078). The
  window is a 600 × 360-point icon view without toolbar, sidebar or status bar,
  with 128-point icons and 13-point labels, MacEase.app centred at (160, 164)
  and Applications at (440, 164), over `scripts/dmg-background.tiff`: a pale
  ground with the app icon's highlighted menu row (a blue capsule with a white
  bar and chevron) between the icons and no text.
  `swift scripts/make-dmg-window.swift background` regenerates the image. The
  exact window height, label placement and label colour in Dark Mode have not
  been checked in Finder.
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

## 20. Version 2.0

The owner approved this complete scope on 2026-11-01. These requirements
supersede conflicting v1 restrictions above. They describe acceptance targets,
not evidence that a feature has passed verification. See ADR 0043.

### 20.1 Organization

Finder's Organize action processes loose regular files directly inside selected
roots. An initial policy and proposed changes require confirmation. Subsequent
runs may create categories and move files under that approved policy, using
existing subfolders without restructuring them. Moves stay inside the same
root and volume; symlinks, packages and special entries are not traversed.
Only opaque generated filenames are renamed; descriptive names remain.

Classification uses bounded image, PDF, text and supported document content,
representative video frames and metadata, and audio tags. Analysis stays local.
An unavailable model or uncertain classification leaves the file unchanged with
a visible reason. Model responses are proposals, never filesystem authority.
Category identifiers and name components are validated before mutation.
Explicit classification corrections are retained for later runs, without
claiming model fine-tuning or inferring rules from unrelated Finder moves.

Watching is a separate opt-in from Finder folder access. Event-driven watchers
wait two minutes for new files and confirm stable writes before processing.
They reconcile on startup, serialize each root, suppress self-generated work,
and do not immediately reorganize files restored by Undo. Each root can pause.
Recent organization results show old and new paths, support old-name search,
classification correction and batch Undo.

Moves use the existing commit gate, naming serialization and file coordination.
They verify source and destination identity immediately before committing and
record durable intent before moving, followed by completion. Startup reconciles
unfinished intents without overwriting or guessing ambiguous identities.
Undo removes only directories created by that batch, still having the recorded
identity and now empty. Existing history remains readable.

### 20.2 Batch and document editing

Photo editing accepts multiple still images with a file list and per-file edits.
Applying adjustments to selected images is one session Undo step; subsequent
edits remain independent. Source stamps and save policies are never copied
between images. Automatic enhancement analyzes each source separately. Only
the selected source and bounded previews remain decoded. Existing RAW, HDR,
animation and multipage protections continue to apply individually.

The video editor accepts multiple sources and source-referenced segments.
Import, split, delete, duplicate, reorder and segment adjustments use the same
source/time mapping in preview and export. Initial output canvas and frame rate
come from the first source; other dimensions fit with letterboxing. Silent
segments contribute silence even when only later sources have audio. All source
identities are checked before final commit. Joined output is always Derived,
and HDR, alpha or metadata changes are disclosed before saving. Existing
single-source payloads remain readable. Multitrack editing, transitions and
subtitle editing remain outside this release.

PDF Edit Pages accepts one PDF, ordered page selection, deletion, and session
Undo/Redo. Empty or unchanged plans cannot save. It follows the existing output
mode, with `_edited.pdf` for Derived names. Source identity and document
permissions are checked; surviving annotations, form values, outlines and
internal destinations require output verification. This adds no PDF text editor.

### 20.3 Finishing recipes

Versioned local recipes support editing, duplication, deletion and bundled Web
Publishing and Submission examples. Image, video and PDF rules define final
formats, dimensions, compression, naming and multiple variants. Video
thumbnails and PDF image/text exports reuse existing operations. Each run
snapshots its complete recipe and settings. Every variant starts from its
original; published intermediate files never feed lossy conversions.

A run produces one named folder or ZIP, always retaining every source. Mixed
source parents require a destination picker. Unsupported selections are
reported before execution, never silently omitted. All required outputs are
generated and individually verified in destination-volume staging before one
Derived commit. Final commit rechecks every source stamp. Cancellation and
failure publish no incomplete package. One history batch supports Undo.

Optional total limits count output file bytes for folders and actual archive
bytes for ZIP. Bounded retries may redistribute budgets using existing
compressors. An unattainable limit fails visibly; arbitrary PDF compression
ratios and unlimited quality degradation are not promised. The complete recipe and applicable settings are fixed at run start; later
settings changes cannot affect an in-progress run.
Recipe menu leaves carry stable identifiers and revisions covered by the
catalog hash; authenticated URL transport remains unchanged.

### 20.4 Verification and release

Implement independent output and recovery checks, actual Finder/Services flows,
English/Japanese, light/dark, keyboard and accessibility behavior. Measure
photo preparation/interaction/memory, video preparation/seeking/export, and
watcher idle load against the same baseline fixtures on the available Mac.
Do not claim speedups that measurements do not establish.

Run build, strict lint and device tests. After integration, three fresh
GPT-6.1 Sol/high reviews cover features/UI/specification, output/safety/concurrency,
then the corrected complete diff and physical evidence. Fix reproducible,
material defects; do not add speculative machinery for low-impact hypotheticals.
Version 2.0.0 uses build 6, the existing signing identity and disabled Actions.
Publish a tagged-source signed DMG, checksum and verified GitHub release.
Earlier VoiceOver and macOS 26 VM exclusions do not extend automatically; if
these checks remain unavailable, seek a specific decision after other work.
For v2.0.0 only, the owner explicitly excludes actual VoiceOver reading and
navigation from mandatory acceptance on 2026-11-01. They remain unverified,
not passed. The macOS 26.6.2 VM smoke check was completed and is not excluded.
All other release requirements remain in force (ADR 0044).

## 21. Version 2.1 stabilization

Version 2.1.0, build 7, prioritizes target-size compression, conversion and
complete UI verification. Custom 10 MB means at most 10,000,000 bytes.
Compression keeps the source format and dimensions first, then uses permitted
palette reduction and downscaling. An unmet limit is a failure, never success.
Conversion success does not promise a smaller file. Already-satisfied inputs
and outputs that cannot shrink remain distinct skipped outcomes.

### 21.1 Compression and feedback

Remove redundant PNG encoding, decoding and full-frame candidate retention.
Keep explicit working memory within its existing budget; do not trade away
16-bit precision, HDR, profiles, metadata or alpha for speed. Optional lossless
optimization and target-size success are separate facts. Explain any skipped
optional step without implying that a verified compressed output was not
created. Show the actual processing phase and elapsed time, and check
cancellation within expensive pixel work. Image compression owns its downscale
and animation frame-rate preferences. Migrate absent image preferences from
the previously shared video preferences without changing saved behavior.

Before and after measurements use identical Release builds, machine and
12/24/48 MP photograph-like, text, transparency and gradient fixtures, with
three runs per side. The initial latency thresholds were ten seconds for 24 MP
and thirty seconds for 48 MP. The owner subsequently requested completion in
a few seconds; reaching the initial thresholds alone no longer establishes
the requested speed. The owner accepts resident memory around 1.56 GB,
including the observed candidate-6 peak of 1,567,784,960 bytes (ADR 0048).
This does not authorize an unlimited increase or a larger working budget.
The owner subsequently authorized quality and resolution reductions when
substantial size savings require them, and requested a balanced result rather
than exhaustive quality-first search (ADR 0049). Avoid unnatural colors,
damaged text/edges or transparency artifacts. Keep source protection, profiles,
metadata and higher-precision/HDR contracts. Measure completed outputs;
skipped work and failed attempts are not speedups.

### 21.2 Activity comparison and retry

Activity retains bounded, session-only request/settings snapshots and per-item
source identity, actual sizes, dimensions and applied image changes. This does
not change persistent history or authenticated Finder request URLs.

Static image conversion and compression results offer side-by-side source and
output comparison, synchronized zoom/pan, Fit and 100% views, actual sizes,
reduction, formats, dimensions and quantization/downscale disclosures. Never
recompress for comparison. Replace mode reads the original from its recorded
Trash location without restoring it. Revalidate source and output identities;
missing or changed files report why comparison is unavailable. Animated and
multipage output cannot be represented as a single-frame comparison. PDF
conversion creates a document and does not offer static-image comparison.

Retry applies to failed image/video/audio compression and conversion, and PDF
compression. Exclude successful, skipped and explicitly cancelled items.
Snapshot the original options and settings, allow target-size changes for
size-limited compression, and create a new batch. Check input identity and
prevent duplicate concurrent retries. A changed or missing input requires a
new selection; no implicit use of a different file at the same path.

### 21.3 UI and release acceptance

Inspect every panel and settings page, Activity, Welcome, editors, ZIP/SVG,
organization, recipes and Finder/Services entry points. Verify English and
Japanese, light/dark, minimum/normal sizes, long names, empty/loading/error and
disabled states and keyboard focus. The editor action row uses
consistent native controls without duplicate menu indicators or glass layers.

Run build, strict lint, device tests, signed Finder/Services operations and a
macOS 26 VM smoke check. Three fresh GPT-6.1 Sol/high reviews cover compression
and performance, UI and the new result actions, then the corrected complete
diff and evidence. Fix material reproducible defects before publication.
The owner explicitly removed VoiceOver support and verification from v2.1
onward on 2026-11-02 (ADRs 0047 and 0048). This supersedes earlier VoiceOver
requirements; support is not claimed and speech checks are not release gates.
Preserve existing native semantics and labels, and distinguish unverified
speech checks from successful tests.

Retain the existing signing identity and disabled Actions. Publish a DMG built
from the final tag with its SHA-256 and release notes, verify installation and
settings/history compatibility, then anonymous downloads and latest-release
resolution. No unperformed check is recorded as passed.

## 22. Version 2.2 media downloads

Version 2.2.0, build 8, retains MIT for MacEase source, Apple Silicon and macOS
26 or later. Existing compression and conversion engines remain unchanged.
Intel support, older macOS, browser cookies, login integration, DRM removal,
and recording currently live streams are outside this release. Public live
archives use the ordinary download path. Website changes can prevent extraction;
never promise every site works.

### 22.1 Finder and download window

A top-level **yt-dlp…** action appears for folder backgrounds and exactly one
selected folder. The background target or selected folder is the destination.
Mixed selections and multiple folders do not expose the action. The authenticated
run request and host validation remain mandatory; the extension performs no
network work. Finder Services provides the same operation where applicable.

A native window starts with one URL field accepting newline-separated HTTP(S)
URLs; Return or Analyze (⌘R, shown in its tooltip) obtains titles, durations,
dimensions and formats. While results are listed, Return in the field downloads
the selection; editing the URLs clears the results, so Return analyzes again.
The idle state shows one line and, when applicable, Paste Link from Clipboard. Results
list each source with a checkbox, host, duration, largest dimensions and playlist
status. Options choose Video, Audio Only or Images; video/audio expose the
matching format, resolution and subtitles (Images uses section 24.1); the footer shows the destination folder. Choose… replaces that
folder for this window through a directories-only open panel; batch planning
revalidates it as a non-symlink directory. Playlist entries require
explicit selection before download.
Download keeps the window open, clears the URLs and lists each submitted item
from JobCenter progress: queued, downloading or converting with progress, done
with Show in Finder, cancelled, or failed with the one-line Activity reason and
Retry. Retry resubmits only that failed, non-cancelled item. Closing the window
never cancels downloads; Activity still reports them.
Each row receives its final result as that item finishes, without waiting for
the remaining downloads in its batch.
Independent invocations retain their own destination and draft. Native controls,
lightweight tables and standard title bars follow Finder and Safari conventions.

Default to best available video in its source format, without unnecessary
re-encoding. Also offer MP4, MKV, WebM, original audio, M4A, MP3, WAV and FLAC.
The Format menu groups No Re-encoding (Original Format, MKV) and Converts If
Needed (the rest). M4A and MP3 offer Quality: Standard (192 kbps AAC or VBR
MP3), 128, 256 or 320 kbps, applied only when the audio is converted. When
selected items share no resolution, a caption says each downloads at its best.
Resolutions come from available source formats. Disclose required re-encoding;
never silently change requested quality or format. Subtitles default off; select
language, authored or automatic captions, and SRT or VTT sidecars.

Dropping browser links onto the window appends HTTP(S) URLs and analyzes them.
On opening with an empty URL field, the window asks the system whether the
clipboard probably holds a web URL without reading it; only then does it offer
**Paste Link from Clipboard**, which reads the clipboard when clicked. After an
analysis, rows show the source's thumbnail: HTTPS-only URLs without credentials,
fetched with an ephemeral session (no cookies), at most 4 MB each, four at a
time and 64 per analysis, decoded to 320 pixels. Failed thumbnails keep the
placeholder.

Queue at most two downloads concurrently. Cancel stops child processes and
removes uncommitted staging. Retry only failed selections, never successful or
explicitly cancelled ones; resolve fresh media URLs from the original page.
Completed downloads support Show in Finder and Undo through normal history.

### 22.2 Runtime and file safety

Bundle source-distributed Unlicense yt-dlp, a private Python runtime, EJS and a
source-built QuickJS-NG 0.18.0 runtime. EJS 0.8.0 runs only through that explicit
runtime, without remote components or automatic fallback. Do not link the stock
CLI or `quickjs-libc`. The solver CLI reads only its caller-selected input script
before evaluation, exposes `console.log` and ordinary language/base64/clock
intrinsics, and rejects every module load. JavaScript cannot access files,
environment variables, processes, workers or the network. Gate the media build
and package test command with real denied-I/O probes and a global allowlist.
This is an API boundary, not an OS sandbox or a CPU/memory limit. Solver temporary
files stay in per-request staging and are removed on completion or cancellation.
QuickJS-NG needs no JIT entitlement. Omit Python GUI/bootstrap packages, unused
certifi tests and bytecode caches; retain runtime source and extension modules.
Launch Python with isolated imports and bytecode writes disabled. Never depend
on the user's Python or Homebrew.
Bundle FFmpeg and ffprobe as independent processes, built without GPL or nonfree
features, for downloading, merging, converting and repairing newly downloaded
media, local MP3 encoding under section 23, and decoding unreadable local
inputs into a staged intermediate under section 25.3. Their required LGPL
dependencies share this narrow exception.
MacEase source remains MIT; third-party executables retain their own licenses.
Strip debug and local symbols from media/audio native helpers before signing,
while preserving external symbols and all executable sections. Keep audio model
files unchanged and hash the signed helpers in their runtime manifest.
Pin source versions and hashes, provide notices and corresponding source/build
instructions, sign nested executable code, and update tools with app releases.
No runtime self-update, arbitrary user arguments, plugins or user configuration.

Use executable URLs and argument arrays, never a shell. Validate untrusted URL,
metadata and output-name boundaries. Keep resolved URLs and download requests
session-only and omit credentials or query strings from logs. Downloads are
explicit network requests, not telemetry.

Stage on the destination volume outside the user's folder. Verify media and
subtitle outputs before a coordinated no-overwrite commit. Collision numbering,
crash cleanup, cancellation and durable history apply. Newly downloaded files
must never replace existing user files, regardless of the transform output mode.

### 22.3 Measured progress and updates

Activity auto-appears after two seconds without taking Finder focus. Closing it
hides progress without cancelling. Show completed batch count separately from
current-file stage progress. Use actual bytes, frames/media time, pages or known
work units. Unknown totals and compression searches show an indeterminate bar
and the actual phase; elapsed time and maximum attempt counts are not completion
fractions. Phase changes reset stage measurements and ordered snapshots reject
stale delivery. Only verification and final commit establish batch completion.
HatchZip retains its existing pause/recovery semantics.

The update API remains GitHub; menu and notification actions open the localized
official download page. Migrate persisted release links. Other native media processing is not replaced by FFmpeg.

### 22.4 Acceptance and publication

Verify real Finder/background/Services entry points, per-window destinations,
URL analysis, playlist choices, formats, subtitles, retry, cancellation, Undo,
name collisions, invalid inputs, permissions, disk-full and interrupted transfers.
Use fixed HTTP fixtures for MP4, separate streams, DASH and HLS, plus public
YouTube, TikTok and another extractor. Record site-specific restrictions honestly.
Verify two-second timing, determinate/indeterminate stages, parallel events,
preference migration and official-site update actions.

Run build, strict lint and device tests, English/Japanese and light/dark window
checks, keyboard operation, macOS 26 VM checks, and independent fresh review.
Preserve the existing signing identity, settings/history and disabled Actions.
Publish from the final v2.2.0 tag with signed DMG, SHA-256, release notes and
required third-party source. Check final-DMG installation, anonymous downloads,
latest-release resolution and the website's matching download information.

## 23. Audio preservation and timeline stabilization

### 23.1 Audio extraction and MP3 output

Extract Audio starts with **Extract Original Audio**. It selects a compatible
copy target (AAC/ALAC in M4A, MP3, FLAC, Vorbis, Opus, WAV or AIFF), ignores
encoding bitrate preferences, and never falls back to encoding. Unsupported
codec/timing combinations fail explicitly. Source files are always retained.
Existing explicit format choices and recorded operations remain readable.

All local MP3 encoding uses the existing pinned FFmpeg/libmp3lame executable
through a bounded PCM pipe. The original application code stays MIT; no LGPL
implementation is copied or linked into it. Keep separate notices, matching
sources and build instructions. Do not add gain, normalization, pitch, channel
mixing or repair to extraction. Explicit Normalize retains its requested gain.
CBR/VBR preferences and supported bitrates remain unchanged. Preserve tags and
encoder delay/padding. Unsupported descriptive tags refuse replacement; New File
warns while preserving supported tags and the source. Cancellation terminates the encoder and discards staging.
Missing tools fail explicitly; there is no old-encoder fallback. Native app
builds resolve their bundled tools. Command-line package clients may select a
runtime directory with `MACEASE_MEDIA_TOOLS`; make test and benchmarks supply
the pinned repository runtime.

Decoded PCM from AVFoundation tracks uses the richest decodable layer of the
track description, so HE-AAC SBR and parametric-stereo output rates and channels
drive every encoder and timing check. A decoded buffer whose rate or channel
count differs from the description fails instead of being retimed or dropped.

### 23.2 Shared timeline interactions

Video and audio use yellow retained ranges with draggable 12-point chevron end
handles and a resize cursor, a white playhead with a ruler knob and a pink hover
skimmer that labels its time. Rounded clips sit under an `m:ss` ruler with minor
ticks; trimmed-away media is dimmed. Video skimming previews silently;
leaving restores the committed playhead and playback takes precedence. Audio
shows a progressively decoded waveform; video clips add a teal waveform lane
under their thumbnails, decoded once per source in the background (MP4/MOV and
the in-house Matroska/AVI decoders alike; silent sources show none). Fades draw
as shaded ramps at clip or selection edges.

Transport controls offer Loop Playback (the whole output in the video editor, the
selection in audio trim) and J/K/L shuttle: L plays forward and doubles the rate
on each press up to 8×, J does the same in reverse, and K pauses. Rates above 2×
are muted in both windows; rates are limited to what the item supports. When
AVFoundation cannot play an item in reverse, J steps back one
frame (video) or one second (audio) instead. The current non-1× rate is shown. Click commits the playhead. Command
plus wheel, pinch, the zoom slider and Command plus/minus zoom around the pointer;
Fit restores the whole timeline. Ordinary scrolling pans. Only visible content
is drawn, including waveform refinement at higher zoom.

Handles snap within eight screen points of the committed playhead or segment
boundaries; Option bypasses snapping. Set Start/End at Playhead is also available.
The audio trim window types boundaries as `m:ss.sss`, `h:mm:ss.sss` or seconds.
Unparsable entries are outlined and disable Trim; ranges that would invert are
not applied. An untouched field never re-commits its rounded text, and Trim
commits pending typed boundaries before it runs.
Video endpoints resolve against actual source frame times; audio endpoints
resolve to samples. A drag snapshots its original range and time scale and is
one Undo action. Preserve split, delete, duplicate, reorder, multi-source editing,
speed mapping and numeric inputs. Mutation closures edit a local value before
publishing it, avoiding nested exclusive access to observable state. Closing
cancels waveform, trim and seek work, stops playback and removes preview staging.

### 23.3 Download feedback and verification

Show offered video dimensions, excluding storyboard and audio-only streams from
resolution choices. A single offered resolution must be understandable without
inventing smaller source formats. Settings remain usable at the minimum size
in both languages and appearances. Missing HLS/DASH fragments fail instead of
publishing a shortened result. Strict decoding remains mandatory. A narrowly
recognized trailing empty H.264 type-zero filler may be removed by packet copy
only after a strict failure, with identical retained packet hashes and times
and a successful complete decode afterward. Other corruption remains an error.

### 23.4 Verification and delivery

Audit every operation group for unintended transforms, source protection,
preview/export consistency, configuration isolation, cancellation and Undo.
Record existing proof, new findings, actual checks and unverified behavior.
Keep independent MP3 quality/bandwidth/duration/channel/tag tests while replacing
the obsolete encoder, and test trim through the real app model. Build, strict
lint, device/package tests, app tests, physical interaction checks, English and
Japanese layouts, light/dark and macOS 26 smoke checks remain required. Fix
material review findings without weakening acceptance.

The owner superseded the earlier commit-only delivery on 2026-11-05 with
the v3.0.0 implementation and publication described in section 24.
Preserve the existing signing identity and disabled Actions.

## 24. Version 3.0

Version 3.0 retains the original-file, staging, verification and Undo contracts.
The owner authorizes logical commits, pushing and a new signed GitHub release
after verification. Release acceptance is recorded separately from implementation.

### 24.1 Acquisition

One **yt-dlp…** window groups Video, Audio Only and Images without
per-site Finder entries. Video/audio use yt-dlp. Images uses gallery-dl 1.32.20
as a separate, unmodified GPL-2.0-only CLI with its license and matching source.
No GPL implementation is copied or linked into MacEase's MIT source.
Pin every runtime dependency, disable user configuration, plugins, credential
discovery and self-updates, and retain the existing verified no-overwrite
commit path. Public URLs only; no login or DRM circumvention.

Image acquisition accepts direct posts/albums with 1–512 images. Analyze with
`--dump-json`; reject errors, child-gallery/recursive records and excess images.
Profile and collection crawling is unsupported. Validate decoded images before
publishing a new folder. Its `MacEase Source.json` records source page URL,
retrieval time, tool and filenames. Video/audio outputs store the page URL in
`com.apple.metadata:kMDItemWhereFroms`.

Recorded links are editable metadata and do not establish authorship or authenticity.

### 24.2 Local sharing

**Share with QR Code…** serves 1–20 selected regular files through a temporary
private-LAN HTTP server. The window displays a QR code, file list, expiration,
interface selection and Stop Sharing. Starting sharing is explicit. The URL
uses a cryptographically random 32-byte token, expires after fifteen minutes
and becomes invalid on stop or window close. The window must remain open.
Anyone possessing the link can download during that lifetime.

Only selected files are served by opaque identifiers; arbitrary paths,
directory traversal, uploads and public-interface access are forbidden.
Responses stream with bounded memory. Source changes fail the transfer.
Explain that the receiver needs the same trusted private Wi-Fi or Ethernet
network and HTTP is not encrypted; no cloud service or internet port forwarding
is involved. Android and other devices use their browser without an account.

### 24.3 Local enhancement

Models and inference dependencies are pinned in section 3.7 and bundled with
the app, independently licensed for distribution. No runtime model download,
model-installation UI, Apple Intelligence dependency or media upload is involved.
Missing resources and unsupported inputs fail explicitly. All outputs are new
Derived files through the existing staging/verification/commit pipeline;
originals remain untouched. Cancellation removes unfinished staging.

| Operation | Input scope | Output and execution |
| --- | --- | --- |
| Upscale Photo… | One opaque, 8-bit SDR still, at most 1,000,000 pixels; reject HDR, alpha, animation and multiple pages | Swin2SR Core ML 2× tiled inference; new PNG, no implicit downscale |
| Enhance Audio… / Clean Speech | Known duration up to 600 seconds, mono or stereo | GTCRN; explicitly downmix stereo; 16 kHz mono WAV |
| Enhance Audio… / Vocals and Instrumental | Known duration up to 300 seconds, mono or stereo | Spleeter 2stems; both vocals and instrumental, 44.1 kHz stereo WAVs |

Audio runs locally on CPU with one thread in ten-second segments with one
second of context on either side and bounded WAV assembly. FFmpeg decodes,
resamples, downmixes and pads inputs. Tags are not copied. The output containers
are 32-bit float WAV but the native tools use 16-bit intermediates; do not claim
restored precision. Multichannel or unknown-duration input fails explicitly.
`docs/ai-audio.md` records exact model provenance, independent checkpoint
comparison, rate-metadata correction and frame/timing validation boundaries.

`docs/upscaler.md` records conversion checks and measurements: on an Apple M5
with 24 GB, 1000×1000 input took 134.42 seconds with 1.33 GB RSS. These are
observations, not performance or perceptual-quality guarantees. Enhancement
is a transformation and cannot establish authentic detail. The build-only
pinned conversion environment is created by `scripts/build-upscaler.sh`;
Python, PyTorch and Transformers are not shipped for image inference.

### 24.4 Finding and protecting files

**Find Related Files…** starts from one regular file. Default scope is its
containing folder, with an explicit folder picker to change the scope.
Exact-content matches require equal size, SHA-256 and byte-by-byte comparison.
Similar images use local Vision feature prints with distance at most 0.5 and
are labelled as similarity, never duplicates. Results reveal selected matches
in Finder and never move or delete files. Skip symlinks and package descendants;
surface unreadable or changed inputs.

**Encrypt or Decrypt…** uses official age v1.3.2 through the isolated bridge,
with standard age v1 scrypt passphrase ciphertext, not a custom format.
New passphrases require at least 12 characters and confirmation. Passphrases
are session-only and delivered only through length-prefixed standard input,
never arguments, environment variables, files, logs or history. Explain that a
forgotten passphrase cannot be recovered; clear panel fields on submission/close.

Encryption decrypts the staged ciphertext and compares complete SHA-256 and
byte count before publishing. Decryption completes authentication before
publishing plaintext. Both preserve sources and use collision-safe new names.
Wrong passwords, corruption and truncation must not publish partial plaintext.
Empty plaintext is supported and covered by native round-trip checks and
engine integration regressions.
`docs/encryption.md` records the bridge and interoperability contract.

HatchZip v0.1.10 includes fixes for dot-only paths, hard-linked volumes and output verification
before archive-byte reclamation. Preserve its destructive extraction warning,
durable recovery and existing format scope: no HatchZip RAR or tar.xz support.
`docs/hatchzip-update.md` records the exact pin and focused verification.

### 24.5 Acceptance

Finish and review interrupted audio fixes before integrating new features.
Run strict lint, package tests, app tests and release build checks. Package
acceptance runs with `--no-parallel` so resource-heavy suites do not starve
time-sensitive cancellation observations; explicit concurrency tests retain
their own parallel work (ADR 0060). Exercise
new windows and real outputs, cancellation, collisions and source retention.
Test sharing authorization and expiry, download isolation and output validation,
encryption interoperability/tampering, and independently verified match results.
Record model provenance and actual enhancement checks without quality claims
unsupported by observations. Check final-DMG installation, signatures,
third-party notices/source, anonymous downloads and latest-release resolution.
Remove only identified regenerable artifacts and stop obsolete app instances
after confirming they have no active work.

## 25. Version 3.1

### 25.1 Finder Preview

Finder Preview is a host-owned panel, not a Finder Quick Look extension. Its
presence follows one saved setting, `finderPreview.enabled` (off by default and
after Reset All Settings), rather than an open or closed panel (ADR 0072).
While the setting is on, the panel docks beside the front Finder window whenever
one is visible. It hides when there is no Finder window, when the window is
minimized, hidden or on another Space, and when Finder quits, and it returns by
itself for a new window, a Finder relaunch, a MacEase relaunch or a login.
Closing a Finder window does not turn the setting off. The panel's close
button, Command-W, closing the permission notice window, the Finder command
(section 4.5), the menu-bar **Finder Preview** item (section 6) and the
authenticated `macease://preview` route (section 3.3) all flip the setting;
Escape does not close the panel. menu.json and the menu-bar checkmark follow
the setting. Turning it off removes observers and timers, cancels file
inspection, and invalidates pending selection results. An already executing
Apple event finishes or reaches its two-second timeout; its result cannot show
the panel again.

The docked panel is borderless and nonactivating, can become key but not main,
uses normal window level, joins the active Space and full-screen spaces as an
auxiliary window, and becomes key only when a control needs keyboard input, so
clicking a button or the player leaves Finder's keyboard focus alone. Clicking
or selecting in text or a rendered page makes the panel key. It sits flush
against the Finder window with the same top and height. Its content is clipped
to Finder's 16-point continuous corner radius on the outer corners only, keeps
the system window shadow, and draws a one-pixel separator on the joined edge.
It orders directly above the matched Finder CGWindowID, including when another
application is frontmost. AX focus, main-window, move, resize, destroy and
minimize/deminimize notifications coalesce; workspace events and a half-second
visibility check detect hiding, Spaces and z-order changes, and only a change
re-docks the panel. Minimized, off-Space and closed windows do not leave a
floating preview behind.

AX global top-left coordinates convert to AppKit with
`x = ax.x; y = primaryScreen.frame.maxY - ax.maxY`, preserving width and height.
The target screen is the one with the largest window-frame intersection. Match
CG windows by Finder PID, normal layer and bounds within two points. Use the
screen's visible frame for docking: right edge first, left if right does not fit,
otherwise inset over the window's right side and clamp horizontally to the screen.
The panel keeps the Finder window's height and top. Width defaults to 360 points
and is clamped to 280 through half the usable screen width. The preferred width
is saved in UserDefaults only when the user resizes the panel; clamping on a
smaller screen changes the displayed width without overwriting it. The resize
edge is the edge that moves when the width grows: the outer edge for right and
left docking and the leading edge for inset docking, so it follows the pointer.
Dragging never exceeds the room on the current side. The edge shows a resize
cursor and a small grip on hover. On an unusually narrow screen, the half-screen
cap takes precedence. Finder itself is never resized. The first appearance after
the user turns the setting on fades in while sliding 20 points out of Finder over
0.16 seconds with a strong ease-out; turning it off reverses this over 0.12
seconds, and Reduce Motion keeps only the fade. Automatic reappearance and
following use immediate frame updates.

A single compiled NSAppleScript runs on a serial background queue with at most
one request in flight. The script reads the front-window ID and the selection
URL descriptors, validates local file URLs, and detects a front-window change
during the script; it also returns the front window's folder and view mode
inside `try` blocks for the storage bar (section 25.2). MacEase asks macOS for
Finder Automation consent only after a user action: turning the preview on, or
Try Again. At launch, an undetermined consent shows the Automation notice
instead of a prompt, and a request that may ask is never dropped behind silent
polls (ADR 0068 describes the consent call). The two-second timeout applies only
to selection reads. Polling runs every 250 ms only while the panel is docked and
Finder is frontmost; turning on, window changes and focus changes request an
immediate read. Window IDs and a selection generation reject stale results.
Timeouts, an unavailable Finder and window-ID races are retried quietly on the
next poll while the current preview stays visible; after three consecutive
failures (0.75 seconds) the panel shows the problem and backs off for two
seconds. Denied Automation shows its notice at once and stops polling until Try
Again. Changing the file types or trusted folders in Settings re-evaluates the
current selection at once; appearance settings apply without reloading.

The Accessibility prompt appears only when the user turns the preview on; it is
never shown at launch. Until Accessibility is granted, a centered titled,
resizable window (360 by 600 points, minimum 280 by 420) lists the two
permissions in order, 1 Accessibility and 2 Automation, each with its status and
a System Settings button, and checks Accessibility every second so that the
panel docks as soon as it is granted. Try Again remains for Automation denial,
timeouts and tracking failures. Other tracking, selection and file failures are
logged and shown explicitly. The host declares an English
NSAppleEventsUsageDescription. The Finder extension remains sandboxed and never
reads selected file contents.

**Layout.** The panel uses the opaque system window background with 16-point
margins and shows only the file's content. One 52-point top bar, aligned with
Finder's toolbar, holds the viewer's controls on the left and, on the right, the
"n of m" stepper (multiple selections only) and the close button. The stepper
uses at most 45% of the bar and collapses from "12 of 48" to "12/48" to arrows
only; VoiceOver still reads "12 of 48". Viewer controls drop secondary text and
then collapse labels to icons before anything truncates. One-line notes, such as
a name mismatch or a restriction, sit under the bar with their full text as a
tooltip. Images, video, PDF and Quick Look fill the panel edge to edge. The
panel waits only for the file kind, not for metadata, decoding or folder walks.
While the next file is inspected, the previous preview stays visible; after
200 ms it dims to 40% with a small spinner tied to the current selection, without
a cross-fade. When the previewed file changes, VoiceOver announces "name, kind"
using the file system's kind, queued after current speech. With a multiple
selection, Command-Option-Left and Command-Option-Right step through it, and
Space plays or pauses media and animations. These panel shortcuts give way to
the first responder: they do nothing while focus is in text, a field editor,
web content or any responder holding a copyable selection, including Live
Text, PDF and web selections, and under Full Keyboard Access Space stays with
the focused control. Tooltips name the shortcuts.

**Viewer selection.** A folder or package always uses QLPreviewView, even when
named like a file. Regular files resolve by UTType conformance and extension:
PDF; HTML (`html`, `htm`, `xhtml`); property lists; JSON; Markdown (`md`,
`markdown`, `mdx`); SVG; fonts (`ttf`, `otf`, `ttc`, `otc`, `woff`, `woff2`);
images; audio; video, including MKV, WebM, AVI, WMV, ASF, FLV, Ogg video, MPEG,
VOB, M2TS, 3GP and RealMedia; archives (`zip`, `tar`, `tgz`, `tbz`, `tbz2`, `txz`, `gz`, `bz2`, `xz`);
and text, covering source code, plain text, CSV and TSV, XML and a list of
configuration, script and source extensions. Files without a telling extension
open as text by exact name, case-insensitively: `Makefile`, `GNUmakefile`,
`CMakeLists.txt`, `Dockerfile`, `Containerfile`, `Gemfile`, `Rakefile`,
`Podfile`, `Brewfile`, `Fastfile`, `Vagrantfile`, `Jenkinsfile`, the shell
startup files `.bashrc`, `.zshrc`, `.bash_profile`, `.zprofile`, `.zshenv` and
`.profile`, and the dotfiles `.env`, `.editorconfig`, `.gitignore`,
`.gitattributes`, `.gitmodules`, `.gitconfig`, `.npmrc` and `.dockerfile`, plus
any name starting with `.env.` or `Dockerfile.`. `.ts` and `.mts` open as text
unless their content is an MPEG transport stream, which opens as video. `.7z`
and `.rar` keep Quick Look. A type switched off in Settings > Finder Windows
uses Quick Look, and unknown types keep Quick Look.

Before a specialized viewer opens, the first bytes are identified. An empty file
shows "This file is empty." A file named as text, HTML, Markdown, JSON, a
property list or SVG whose content is binary shows "This file doesn’t appear
to be text." and is never decoded. Other mismatches keep the viewer and show
"The file name doesn’t match its content (PNG)." with the detected
format's localized name. Identification reports PDF only with `%PDF-` at offset
zero, distinguishes Mach-O and universal binaries from Java class files, treats
C0 control bytes other than tab, line breaks, form feed and ESC as binary, and
shares the text test with the encoding detection below.

**Trust.** A file is restricted when the symbolic link itself or its resolved
target carries `com.apple.quarantine`; an attribute that cannot be read counts
as quarantined. Restriction wins over Trusted Folders. A file is trusted when its
resolved path lies inside a folder listed in Settings > Finder Windows > Trusted
Folders; the stored paths are standardized and deduplicated. The HTML rules
below and ADR 0073 describe what each state permits. Restricted Markdown embeds
no images, and restricted media is not converted: "This file is from the
internet, so MacEase doesn’t convert it. Open it in a media player."

Specialized viewers:

- **Text and code** use a TextKit 2 NSTextView with logical line numbers, the
  code font and size from Settings (System Monospaced, 12 points, 9–24) and line
  wrapping from Settings (on). Text is selectable and read-only; editing was
  removed. Reads take at most 4 MiB; larger files display the first 256 KiB with
  a note. An excerpt may omit an incomplete final encoded character.
- **Highlighting** covers the first 512 KiB, cut back to a whole UTF-8 scalar,
  off the main actor and cancelled with the selection. A local declarative
  tokenizer has 47 grammars, chosen by exact file name first and then by
  extension (ADR 0084): Swift, C, C++, Objective-C, Objective-C++, Go, Rust,
  Java, Kotlin, C#, Scala, Dart, F#, Visual Basic, Solidity, JavaScript and
  TypeScript, Python, Ruby, PHP, Groovy and Gradle, Lua, Perl, R, Julia,
  Elixir, Clojure, shell, PowerShell, Windows Batch, SQL, JSON (with JSONC and
  JSON5), YAML, TOML, INI-style configuration (including `.properties`, `.env`
  and Git configuration files), Dockerfile, Makefile, CMake, Terraform/HCL,
  Protocol Buffers, GraphQL, CSS (with SCSS, Sass and Less), markup (HTML, XML,
  SVG, property lists, Vue, Svelte and Astro, with embedded `<script>` as
  JavaScript and `<style>` as CSS), Markdown and MDX, LaTeX, reStructuredText,
  AsciiDoc, and diff/patch. PHP starts in markup and switches to PHP between
  `<?php`, `<?=` or `<?` and `?>`. Plain text, logs, CSV, TSV, subtitles,
  `.sln` and Git ignore and attributes files stay uncoloured. Token kinds are
  keyword, type (types and built-ins), string, comment and number, plus added
  and removed diff lines. A word right after `.` is not a keyword unless the
  dot belongs to `...`. Delimiters that cannot be mistaken (block comments,
  triple quotes, Markdown and AsciiDoc fences, raw strings, Lua long brackets,
  heredocs and here-strings) run to their closer or the end of the scanned
  text; single-line strings stop at a line break; multi-line strings opened by
  one quote character stop after 256 lines or 16,384 UTF-16 units. Colours are
  adaptive sRGB values with Increase Contrast variants. In diff and patch
  files, added and removed lines keep their green or red text and get a tint
  across the full width of the view, including empty `+` and `-` lines and
  every wrapped line; the tint lies beneath glyphs and is cut out where the
  selection is drawn, and the empty line after a final line break is not
  tinted.
- **Hidden and direction-changing characters** are marked in the source view
  (ADR 0084). One scanner, `PreviewInvisibleScanner`, decides which characters
  are flagged:
  - Always: C0 controls other than tab, line feed and carriage return; DEL and
    C1 controls (U+007F–009F); U+034F; Hangul fillers (U+115F, U+1160, U+3164,
    U+FFA0); U+17B4–17B5; U+180E; U+2028 and U+2029; bidirectional embeddings
    and overrides (U+202A–202E) and isolates (U+2066–2069); U+2060–2064;
    U+2800; U+FFF9–FFFB; and tag characters (U+E0000–E007F) except inside a
    subdivision flag: U+1F3F4, two lowercase tag letters, one to four lowercase
    tag letters or digits, then U+E007F.
  - U+FEFF anywhere but the first character of the file.
  - Variation selectors U+FE00–FE0F without a base that can carry them: after
    an ASCII character only U+FE0E and U+FE0F after `0`–`9`, `#` or `*` are
    exempt; after other characters they are exempt unless the base is white
    space, default-ignorable or itself flagged. Ideographic variation selectors
    (U+E0100–E01EF) are flagged unless they follow an ideograph.
  - U+200B, except in prose kinds (plain text, Markdown, reStructuredText,
    AsciiDoc, LaTeX and markup) between two non-ASCII letters or marks, as in
    Thai, Khmer or Japanese word breaks.
  - U+200C and U+200D, except next to a virama, next to a right-to-left letter
    or between two emoji.
  - U+200E, U+200F and U+061C: in code and configuration kinds, unless the
    nearest letter on each side within the line is right-to-left; in prose
    kinds, when next to an ASCII letter or on a line without right-to-left
    script. Right-to-left script includes U+10800–10FFF and U+1E800–1EFFF.
  - U+00AD in prose kinds outside a word, and in code next to ASCII or outside
    a word.

  The scan covers the same 512 KiB as highlighting. Marks are drawn by a
  TextKit 2 layout fragment and never stored as text attributes, so
  characters, shaping, Copy, Find, selection, line numbers and wrapping are
  unchanged. Each flagged character gets a 2-point orange bar with a small
  triangle head at its caret position, full line height, above glyphs and the
  selection (adaptive sRGB: #BF5200 light, #FF9E33 dark, #993D00 and #FFBD61
  with Increase Contrast). A character at a line end or wrap break is drawn
  after the last glyph of its visual line. Pointing at a mark shows its code
  point and Unicode name, for example "U+202E RIGHT-TO-LEFT OVERRIDE", with
  `<control>` for unnamed controls and "×2" for stacked characters at one
  position. Bidirectional controls and tag characters are always drawn and
  get a tooltip; other flagged characters are capped at 100 per visible line
  fragment, and the last drawn one then adds "N more hidden characters on
  this line aren’t marked." In Source mode only, when the shown text contains
  a bidirectional control or a tag character outside a flag, an orange note
  says "This file contains N hidden or direction-changing characters.", where
  N counts every flagged character, and "at least N" when the file was cut to
  an excerpt or its text is longer than the 512 KiB scan. Other classes are
  marked without the note. VoiceOver reads the note; marks have no
  per-character accessibility. Files with nothing to mark and no diff lines
  use TextKit's plain layout.
- **CSV and TSV** offer Table and Source; Table is the default for every newly
  selected file. The table is built from the text the viewer decoded, so the
  encoding menu applies to both and a new encoding rebuilds it. Parsing
  follows RFC 4180 (quoted fields, doubled quotes, line breaks inside quotes,
  CRLF, LF or CR record ends, a last line without a break) and accepts ragged
  rows, showing missing cells empty; a quote opens a quoted field only at the
  start of a field, text after a closing quote is kept, an unterminated quote
  runs to the end, and no file is rejected. `.tsv` uses tab. `.csv` honours a
  first line `sep=,`, `sep=;` or `sep=` followed by a tab, which is not shown
  as a row; otherwise the first record is read with comma, semicolon and tab,
  and the separator yielding the most fields wins, ties preferring comma, then
  semicolon. The first row is the column header and stays visible. Columns
  are sized off the main actor from the header and the first 20 rows, measuring
  at most 80 scalars per cell, within 40–240 points, can be resized, and scroll
  horizontally. A column is numeric, right-aligned and sorted by value when
  every non-blank cell is a decimal number (optional sign, digits with at most
  one decimal point, optional exponent; hexadecimal, `nan` and `inf` are
  text). Clicking a header sorts numeric columns by value with empty cells
  first when ascending and other columns with Finder's localized comparison;
  equal values keep file order, and a third click restores file order. Cells
  show one line: line breaks, tabs and other C0 controls appear as Unicode
  control pictures, DEL as ␡, and every character the source view would mark
  as U+FFFD, except that a U+FEFF at the start of a cell is also replaced; a
  cell shows at most 1,000 scalars, cut at a grapheme boundary with an
  ellipsis, and its tooltip holds the cleaned text. Rows can be selected;
  Command-C copies the selected rows, without the header, as tab-separated
  text, quoting cells that contain a tab, a line break or a double quote.
  Table mode shows no hidden-character note. The table holds at most 50,000
  data rows and 256 columns; a note says "Showing the first 50,000 rows",
  "Showing the first 256 columns" or both. Files over 4 MiB open in Source,
  and Table then shows "Files larger than 4 MB can’t be shown as a table."
  with Show Source. A decode failure shows its message without Show Source.
  Parsing, measuring, sorting and Find run off the main actor, are cancelled
  when the selection or encoding changes, and never show a table built from an
  older rendering. Clicking the table makes the panel key; Full Keyboard
  Access reaches it by Tab, and VoiceOver gets a native table labelled
  "Table". Quarantined files are shown.
- **Encodings.** Automatic detection is strict: a candidate must decode with no
  disallowed control, private-use, unassigned, surrogate or replacement
  characters. Byte order marks win, then UTF-32 and UTF-16 by NUL position,
  surrogate pairs and byte-lane statistics, then UTF-8, Shift_JIS (CP932),
  EUC-JP, ISO-2022-JP, Windows-1252 and ISO-8859-1. GB18030 is detected only by
  its four-byte mark; GB18030, Big5 and EUC-KR without a mark are chosen manually
  because their byte ranges overlap the others. The encoding menu lists
  automatic detection, UTF-8, UTF-16, UTF-16 LE/BE, UTF-32, UTF-32 LE/BE,
  Shift_JIS, EUC-JP, ISO-2022-JP, GB18030, Big5, EUC-KR, Windows-1252 and
  ISO-8859-1, shows the detected or chosen encoding, and collapses to an icon
  when narrow. An explicit choice re-decodes the retained bytes without
  replacing invalid characters; a decode failure suggests another encoding only
  when the menu is visible.
- **HTML** offers Preview and Source. A file opens in Source unless it is in a
  Trusted Folder or its current version has interactive consent. Preview is
  static, view-only and offline (`staticPreview`): content JavaScript is off;
  content rules compiled before any load deny every scheme except `file:`,
  `data:` and `blob:` and block `^https?://` and `^wss?://`; the website data
  store uses a fail-closed SOCKS5 proxy (`127.0.0.1` on an unassigned port,
  failover off, no exclusions); a guard script in an isolated content world,
  installed at document start in every frame, cancels the default action of
  clicks, auxiliary clicks, Return key presses, `beforeinput`, form submission
  and drags of links, images and media, including events retargeted out of
  closed shadow roots, while text stays selectable, `<details>` still toggles
  and same-document fragment links scroll by id, `name` or GitHub-style heading
  slug; a neutralizer at document end removes `href`, `xlink:href`, `ping`,
  `download`, `action` and `formaction`, disables form controls and removes
  `contenteditable` across HTML, SVG, MathML, open shadow roots and inline-XSLT
  XHTML, keeps link colours, and puts each removed destination in a tooltip.
  The context menu keeps only Copy, Look Up and Speech, plus Share when the
  click was not on a link or image; drops are refused. One button, **Run
  Scripts with Network Access**, switches the current file version to
  `interactive`: scripts and network access together, without the guard
  scripts, for that resolved path and file stamp (identity, size, modification
  and status-change times) until the file changes or MacEase quits. There is
  no state with scripts but without network access. Files in Trusted Folders
  open directly in interactive Preview. Restricted files render a sealed page
  generated from the file's text, allowing only `data:` and `blob:`, with no
  folder access and no interactive button. Unrestricted files directly in the
  home folder, `/Users` or `/` render inline without folder access; other
  files load with `loadFileURL` and read access to their resolved parent folder
  only, so an interactive or trusted page can load files from its own folder,
  including quarantined ones. Every entry into Preview and every reload reads
  the file once through one descriptor, evaluates quarantine, trust and consent
  against those bytes, and checks the stamp and quarantine again immediately
  before loading; any change starts the evaluation again. Navigation permits
  only GET requests for the selected local main document without a query
  change; other files, hosts, schemes, subframes, forms, popups, downloads,
  file pickers and camera or microphone requests are denied. HTML loaded from
  its file may be up to 64 MiB; HTML rendered from text (restricted or in the
  home folder) is limited by the 4 MiB text read and shows "Files larger than
  4 MB can’t be previewed here." with Show Source. Notes under the bar state
  the active state in plain words.
- **Markdown** offers Preview and Source through the safe cmark conversion and
  its 1 MiB input limit, rendered as a sealed generated page with the static
  guard. External links show their destination as a tooltip and stay inert;
  fragment links scroll, so tables of contents work. Images in the Markdown
  file's own folder are embedded as data URLs, at most 8 MiB each and 32 MiB in
  total, through the folder descriptor opened when the file was read, so
  replacing the folder path afterwards cannot redirect them. Symbolic links,
  absolute paths, parent traversal, non-images and remote URLs are not
  embedded. Source remains available when rendering fails.
- **JSON and property lists** offer Formatted and Source using the engine
  formatters. Binary plists display formatted JSON only. Files over 4 MB show
  "Files larger than 4 MB can’t be formatted." with Show Source. Source bytes
  are never rewritten.
- **SVG** offers Preview and Source. Preview draws the file as an image element
  over a checkerboard in a sealed generated page, so scripts and external
  references in the SVG never run; Find is available in Source. A binary file
  named `.svg` is refused as above.
- **Fonts** load TTF, OTF, TTC/OTC, WOFF and WOFF2 files through Core Text and
  show the face name; below it the style name when Core Text has one, the glyph
  count ("Italic · 2,490 glyphs", "1 glyph") and, for collections, "Face 3 of
  4"; and the sample text from Settings at 12, 16, 20, 28, 40 and 64 points.
  Collections add a pop-up menu of every face name with Previous Face and
  Next Face buttons, and the sample switches to the chosen face; single-face fonts show
  no control. Every newly selected file starts at its first face. Files
  over 64 MiB, collections over 64 faces, and WOFF/WOFF2 files whose declared
  or decompressed sizes exceed those limits are refused with a message before
  Core Text sees them; decompression is streamed and bounded. Fonts Core Text
  cannot load use Quick Look.
- **Images** open at Fit. Fit and 100% are toggle buttons that show which one is
  active; any other zoom (pinch, smart zoom) shows a percentage beside them, and
  100% stays exact across displays with different backing scales. Fit can go
  below 1% so very wide images remain whole. Double-clicking or a two-finger
  double tap switches between Fit and 100% around the pointer; double-clicking
  recognized text selects it instead. Zoom changes animate for 0.15 seconds
  unless Reduce Motion is on. The first decode is capped at 4,096 pixels on the
  long edge; zooming past it loads the full image when its pixels need at most
  256 MiB, otherwise the bar shows Reduced and Info lists the reduced size.
  Images over 65,535 pixels on an edge or 500 megapixels are not decoded.
  Images with alpha draw a checkerboard of 8-point squares behind them whose
  shades follow light, dark and Increase Contrast. Images with HDR headroom
  render with constrained high dynamic range. Live Text analyses still images
  between 32 pixels on the short edge and 100 megapixels on device with
  VisionKit, text only, 350 ms after the first frame appears and off the main
  actor; a selection change cancels it. Recognized text can be selected,
  copied and looked up; clicks that start no selection leave Finder focused,
  and the system Live Text button is hidden. The Info popover lists dimensions,
  resolution, color profile, bit depth, HDR headroom, camera, lens and capture
  date when present, and "Location: Included in the file" when GPS data exists;
  coordinates are never shown. Animated GIF, APNG, WebP and HEICS images up to
  2,000 frames play the number of times the file declares (0 means forever),
  stop on the last frame, and restart with Play. Frame delays below 20 ms use
  100 ms and delays above 60 seconds are capped. Frames are cached when the
  whole animation fits in 64 MiB; otherwise each frame is decoded just in time
  with one frame of lookahead. Under Reduce Motion, animations start paused on
  the first frame.
- **Video** uses AVPlayerView's inline controls. **Audio** shows embedded
  artwork, decoded off the main actor at most 512 pixels (artwork over 16 MiB or
  32 megapixels is not used), or the file icon, then title and artist when tagged,
  a full-width scrubber with elapsed time and duration, a play button and a
  mute button (**Mute** / **Unmute**) with a volume slider; volume and mute last
  for the app session. Media that AVFoundation cannot play, such as MKV, WebM,
  Ogg, FLAC or multi-track Matroska, shows "This format can’t be played
  directly." with **Convert and Play**, which converts a temporary copy with
  progress and plays it: compact 192 kbps AAC (ALAC in CAF above six channels)
  for audio, at most 30 minutes of audio, 10 minutes of video and 512 MiB of
  input. Media the native engine cannot decode at all, such as WMV, ASF, MPEG
  program streams, VOB, RealMedia, WMA, WavPack, Monkey's Audio, DTS or AC-3,
  also shows the button; pressing it converts through the staged fallback of
  section 25.3 (ADR 0082). Selecting such a file runs nothing from the
  fallback, not even `ffprobe`: the viewer shows the button after the size
  limit and the quarantine rule. When the button is pressed, `ffprobe` reads
  the duration first, the 10- and 30-minute limits apply ("This file is too
  long to convert for preview. Open it in a media player."), and the
  conversion then has five minutes of wall-clock time. A file whose name
  matches but whose content cannot be read shows the button and fails after
  it is pressed. Playback uses the first video and first audio track; other
  tracks, subtitles and chapters are not played. Quarantined files are never
  converted. Changing the selection cancels the conversion and deletes the
  copy. These throwaway copies skip the stream-consent question of section
  8.2 because nothing is saved. Errors other than a decoding failure show
  their specific message instead of the button. Every preview asset forbids
  external references and shows the message of section 8.2.
- **PDF** uses PDFView with an editable page readout ("3 / 24"; Return jumps;
  invalid entries reset), a table-of-contents popover when the document has an
  outline (at most 2,000 entries), Fit Width and Actual Size, which show their
  state (a zoom menu when narrow), Find through PDFKit with all matches
  highlighted, and an inline password field for locked PDFs: "This PDF is
  locked with a password.", then "The password is incorrect." until new input
  is typed.
- **Archives** show a read-only contents list (ADR 0085). ZIP, TAR, TAR behind
  exactly one of gzip, bzip2 or xz (`tgz`, `tbz`, `tbz2`, `txz` and
  `.tar.gz`-style names), and single `gz`, `bz2` or `xz` files are listed in
  process with libarchive; 7z and RAR keep Quick Look. Nothing is extracted,
  staged or written. ZIP uses the seekable reader with the central-directory
  preflight of section 8.14 and must yield as many headers as the validated
  directory holds. Compressed input passes through two stages: one
  decompression layer reading 4 KiB of input at a time, then a filterless
  TAR or raw reader taking decoded blocks of at most 64 KiB; chained filters
  and filters that would need an external program are refused. Every block
  checks the deadline, cancellation and a 64 MiB decoded-byte budget, with no
  exemption for links, sparse files or PAX headers. Listing stops at 100,000
  entries, 32 MiB of names, 64 MiB of decoded bytes or 10 seconds and says
  which limit stopped it, for example "Showing the first N items." or
  "Listing timed out. Showing the first N items."; with no rows it says why,
  such as "This archive has too many items to list." A damaged archive shows
  the rows read before the damage with a note, or "This archive is damaged,
  so its contents can't be listed." "This archive is empty." is reserved for
  containers with no entries. An all-zero `.tar` of 1,024 bytes to 1 MiB in
  512-byte blocks is listed as an empty TAR. Encrypted ZIP entries show a lock
  and a note. Quarantined archives are listed. Display names are inert:
  controls, line and paragraph separators and bidirectional formatting
  characters show as U+FFFD, names longer than 1,024 scalars are shortened in
  the middle, empty and `.` components are dropped, and `..` and absolute
  paths appear literally as folders. Nesting deeper than 256 levels keeps the
  file under its 256th-level folder with the rest of the path in its name.
  The list is an outline with Name, Size, Date Modified and Kind; Kind hides
  below 600 points and Date Modified below 460. Folders sort first when
  Finder's Keep Folders on Top is set. Sorting and filtering run off the main
  actor; Size and Date Modified keep folders and unknown values last and break
  ties by name. A summary such as "128 items, 45.2 MB uncompressed" sits under
  the bar, counting implied folders as items. The bar holds a Search field for
  names and paths and, for ZIPs, a Browse Contents button that opens the
  section 8.14 window. Rows cannot be opened, dragged or previewed; Copy Path
  (Command-C or the row's context menu) copies the stored entry path byte for
  byte. VoiceOver reads name, kind, size, date and Encrypted for each row, the
  path as help, and announces the summary when listing finishes. Settings >
  Finder Windows has an Archives type, on by default, including for settings
  saved before it existed.

**Find.** One Find bar serves text and source views, CSV and TSV tables,
rendered Markdown and HTML, and PDF. The magnifying-glass button or Command-F
opens it while the panel is key; Return and Shift-Return or Command-G and
Shift-Command-G move between matches; text, tables and PDF show "3 of 12",
while web pages report only "Not found" because WebKit gives no count. In a
table, Find counts matching cells case- and diacritic-insensitively, skips
the header, selects and scrolls to the match and marks its cell with the
system find highlight; sorting recounts in the new order and keeps the current
match. Escape or Done closes the bar and returns focus to the content. The
query persists while the same file stays selected.

File reads, text conversion, image decoding, font validation, PDF opening and
media conversion run outside the main actor; WebKit and AVFoundation use
asynchronous loading. Viewer identity follows the coordinator's selection
generation. Selection changes and a hidden panel cancel tasks, discard stale
results, release viewer content, pause playback and remove time observers.

Full screen, Spaces, Finder tabs, live AX-driven docking, native Quick Look
controls and Increase Contrast rendering require real-host validation with a
trusted build. The CSV and TSV table, font face switching, hidden-character
marks and the archive list were rendered offscreen only; their behaviour in a
real Finder window and with VoiceOver is still to be checked.

### 25.2 Finder storage bar

A display-only strip covers the bottom edge of the front Finder window while
Finder shows its status bar (ADR 0076). MacEase reads Finder's `ShowStatusBar`
preference from `com.apple.finder` with CFPreferences when the strip starts,
when MacEase becomes active and every five seconds. It never writes Finder
preferences and never relaunches Finder. Without the status bar the strip is
absent and Settings explains View > Show Status Bar.

The strip is a borderless, nonactivating panel at normal level, ordered
directly above the matched Finder window. It cannot become key or main, ignores
mouse events so clicks reach Finder's own bar, is excluded from the window cycle
and Mission Control (`transient`), and has no shadow or hover state. It uses
Finder Preview's window tracker and the same selection poll, without a second
Apple event, and it follows the same show and hide rules, cancelling pending
volume work while hidden. Its frame is the window's bottom edge, using the
assumed metrics `statusBarHeight` 20 points, `bottomInset` 0, `iconSliderWidth`
133 points and `iconSliderMargin` 16 points from Finder's StatusBar.nib, which
still need calibration against a live Finder window. Its outer bottom corners use
Finder's 16-point continuous radius. In icon view, and whenever the view mode is
unknown, the strip leaves the trailing 149 points uncovered with a square
trailing corner so that Finder's icon-size slider stays visible and usable;
list, column and gallery views extend to the trailing edge. A docked inset
preview trims the strip to the uncovered side with a square cut corner; right
and left docking leave it whole. A strip narrower than 160 points is not shown.

From left to right it shows the volume name (middle-truncated at 180 points), a
72 × 6-point capsule whose used part is the system accent colour over a
quaternary track, "x available of y", and a right-aligned "n selected" (nothing
for an empty selection). The background is the opaque window background with a
hairline on top; text is 11 points with monospaced digits. As the width shrinks,
the strip drops the volume name, then the capacity text, then the selection
count. Increase Contrast adds a border to the track. A changed value animates the
fill for 0.18 seconds with ease-out, without animation under Reduce Motion.
VoiceOver reads one element labelled Storage whose value is the whole sentence,
without announcements.

The strip never opens, stats, identifies, enumerates or evaluates trust for any
selected item; it shows the selection count only. When Finder Preview is off,
selection results update only the strip. Sizes use the current locale's decimal
file byte-count style. For the startup disk, available space is
`volumeAvailableCapacityForImportantUsage` when positive, which includes
purgeable space as Finder does, otherwise `volumeAvailableCapacity`, clamped to
the total. For every other volume, MacEase never asks for resource values or
display names of a path inside it: capacity comes from the kernel mount table
(`getfsstat` with `MNT_NOWAIT`) and the name from the mount point's last path
component, which avoids file-access prompts and hangs on unresponsive mounts.
A volume without a positive total shows "Capacity unavailable" and no capsule.
The volume is matched lexically from the front window's folder, then from the
first selected item, then from the window's last known folder; without any, or
when the location's volume is gone (such as an ejected `/Volumes/<name>`), the
strip shows the startup disk labelled "(Startup Disk)". Volume reads run one at
a time off the main actor, are bound to the location they were requested for,
and refresh every five seconds while the strip is active.

The strip needs Accessibility and never prompts for it; without it the strip is
absent and Settings shows the status. Without Automation it shows capacity
without the selection count; with no known folder, that is the labelled startup
disk. Strip-only polling never
requests consent, stops retrying after a denial, logs the denial once, and
never puts Finder Preview into its Automation notice or blocks a consent request
made when the user turns the preview on. **Show storage bar in Finder windows**
in Settings > Finder Windows is on by default and independent of Finder Preview;
turning it on reads the selection at once, and turning it off removes the strip.
Measuring the size of selected items is not offered: it would read inside
privacy-protected folders and removable or network volumes on every selection
change and cause file-access prompts. Finder's status bar metrics, colour match,
Spaces, full screen, Mission Control and tabs still need checking on a real Mac.

### 25.3 Media decode fallback

The native engine always reads a video or audio input first. When it cannot
open or decode the file (`decodeFailed` or `unsupportedCodec`), the operation
decodes the file with the bundled LGPL `ffmpeg` and `ffprobe` (section 22.2)
into a temporary intermediate in staging and runs unchanged on that
intermediate (ADR 0082). FFmpeg never writes a user's output and is not used
for Extract Original Audio. Container decodability is checked by scanning at
most 256 packets; frame-rate measurement scans at most 30,000 packets and
fails instead of assuming a rate. Undecodable audio in MOV or MP4 is checked
through `ExtAudioFile` first, so it raises a typed error rather than an
Objective-C exception. The fallback serves Finder operations that read media:
convert, compress by quality, preset or target size, resolution, speed, frame
rate, rotate, trim, remove audio, extract audio, thumbnails, animations,
subtitles, background removal, audio conversion, compression, normalization,
trim, Enhance Audio and Finishing Recipes, plus Finder Preview's Convert and
Play. The photo and video editor opens only what the native engine reads.

`FileKind` classifies `wmv`, `asf`, `mpg`, `mpeg`, `m2ts`, `mts`, `vob`, `rm`,
`rmvb`, `3gp`, `3g2`, `mxf`, `dv` and `ogv` as video and `wma`, `ac3`, `dts`,
`mp2`, `wv`, `ape`, `tta`, `amr`, `ra` and `mka` as audio; `.ts` stays
TypeScript in the menu. Finder Preview offers Convert and Play through the same
fallback (section 25.1). Content identification accepts their signatures; an
MPEG transport stream needs three consecutive sync packets of 188 or 192 bytes,
four when the header covers four.

**A fallback-backed input never replaces its original.** Whatever the
operation or save mode, the result is committed as a new file beside the
original under the operation's ordinary new-file name (`_compressed`,
`_trimmed` and so on), Undo removes only that file, and in Replace mode the
item carries "Saved as a new file: MacEase cannot write the original format."
Replace-only loss refusals therefore become the warnings of a new file. The
decision is made in one place, when the engine settles the item's result.

**Every intermediate is verified.** After staging, `ffprobe` reads the
intermediate and one fixed list of twelve facts is compared with the
original's probe: mapped streams; each stream's start relative to the
earliest; video display dimensions, accounting for rotation, which is baked
into the intermediate's pixels; pixel bit depth and chroma subsampling, each
at least the original's; alpha presence; video frame count within one frame,
or duration within the larger of one frame and 0.05 seconds; audio channel
count; channel layout; sample rate within 1 Hz; audio precision class (lossy,
16-, 24- or 32-bit integer, 32- or 64-bit float); and audio duration within
0.1 seconds, accepting both Matroska `DURATION` conventions. Any unexplained
difference fails the item before the operation runs with "Couldn’t process
“name”: the file couldn’t be converted faithfully. Nothing was changed."

**Intermediates.** Video is written to MOV: 8-bit 4:2:0 SDR as HEVC
(`hevc_videotoolbox`, quality 90, keyframe every 30 frames, no B-frames); 10-bit
or PQ/HLG 4:2:0 as HEVC Main 10; 4:2:2 as ProRes 422; 4:4:4, RGB or odd
dimensions as ProRes 4444; alpha as ProRes 4444 with alpha, decoding VP9 alpha
with libvpx. Other alpha the decoder cannot read fails as unfaithful. Video
soundtracks become uncompressed PCM at 16, 24 or 32 bits or 32- or 64-bit
float. Audio-only input becomes ALAC in M4A when the layout round-trips exactly
(mono, stereo, 3.0, 4.0, 5.0, 5.1 or unlabeled up to two channels) at no more
than 24 bits, and PCM in CAF otherwise. Attached cover art is extracted
separately, at most 16 MiB and 25,000,000 pixels with no side over 16,384;
larger, non-image or undecodable covers are dropped with a metadata warning.

**Losses are reported, not silent.** Facts the intermediate cannot show are
read from the original: Dolby Vision configuration feeds the existing
Dolby Vision warning; track enabled state, preferred volume and alternate
groups, an interlaced field-order change, and differing video tags (key and
value) warn about dropped track metadata; for title, artist and album the
container tag wins over a different stream tag with a metadata warning; an
APEv2 tag larger than FFmpeg's 16 MiB limit or with skipped items warns that
metadata was dropped. A fallback video with variable frame timing (a frame
interval deviating more than 15%, ignoring differences under 2.5 ms) that is
re-encoded without a requested frame-rate change warns "Variable frame timing
converted to a constant frame rate; original kept." Streams the intermediate
cannot carry follow section 8.2: transforms ask, or omit them for new files
under Save without it, before staging; explicit exports take the first video
and audio stream, as the native path does, and report the other streams they
leave out.

**Hardening.** Every `ffprobe` and `ffmpeg` call uses `-protocol_whitelist
file`, an explicit single-family `-format_whitelist` (QuickTime demuxers with
`-enable_drefs 0 -use_absolute_path 0`, or the non-QuickTime list), `file:`
URIs, `-nostdin -hide_banner -n -threads 4`, a clean environment with `HOME`
and `TMPDIR` in staging and `PATH=/usr/bin:/bin`, and no certificate bundle.
External references are rejected on the original before probing and on every
staged output. A probe has a 30-second wall-clock limit; a transcode fails
after 60 seconds without its reported output time advancing. Before staging,
the estimated intermediate plus a margin of up to 512 MB must fit on the
staging volume, and free space and the staged size are rechecked every second;
a shortfall fails with "Couldn’t process “name”: not enough disk space (needs
about …, … available). Free up space and retry." The same message serves
reverse rendering. Child-process failures are typed (timed out, output limit,
disk full, permission denied, signalled, exited), and disk-full or
permission errors are recognised only from the line-final error text, so file
names cannot imitate them. The native error is restored only when FFmpeg also
rejects the media. A missing converter fails with "Couldn’t read “name”: the
media converter component is missing. Reinstall MacEase and retry." Activity
shows **Converting input** with progress before the operation's own phases.
Staging is removed on completion, cancellation and the next launch.

## Changelog

- 2026-11-25: Decode local video and audio that the native engine cannot read
  through the bundled LGPL `ffmpeg` and `ffprobe` into a staged intermediate,
  verified against the original by one fixed fact list, with hardened
  invocations, typed child failures and live disk checks. A fallback-backed
  input never replaces its original; losses it cannot carry are warned.
  Finder Preview's Convert and Play uses the fallback only after the button is
  pressed. This extends the isolated FFmpeg exception beyond downloads and MP3
  encoding (section 25.3, ADR 0082).

- 2026-11-25: Register only in-process gzip, bzip2, xz and zstd archive filters
  and the supported formats. Decode non-UTF-8 entry names archive-wide as
  strict CP932 when Japanese is a preferred language, otherwise CP437 for ZIP
  and a refusal for TAR. Route new CP932 Finder extractions through the native
  staged extractor, which keeps the archive; paused HatchZip sessions resume
  on the route they started with (ADR 0083).

- 2026-11-25: List ZIP, TAR, compressed TAR and single compressed files in
  Finder Preview in process, with fixed entry, name, decoded-byte and time
  limits; 7z and RAR keep Quick Look. Add the Archives file type (ADR 0085).

- 2026-11-25: Highlight 47 languages in Finder Preview with declarative
  grammars, route Makefile, Dockerfile and similar names to the text viewer,
  tint whole diff rows, and mark hidden and direction-changing characters with
  a notice for bidirectional and tag characters (ADR 0084). Show CSV and TSV as
  a sortable, searchable table, and switch between the faces of a font
  collection.

- 2026-11-25: Expose the editor timeline to VoiceOver with segment actions, add
  C to select the segment under the playhead, follow the playhead during
  playback only while it was visible, count photo zoom in real pixels with Fit,
  100%, 200% and 400%, and state the reason on disabled editor controls.

- 2026-11-25: Group the Settings sidebar, rename Text to Text & PDF, add
  Options… for Open Terminal Here and New File, and add If some content can’t
  be kept (Ask, or Save without it for new files only; Replace always asks)
  (ADR 0086). Quote current setting, menu and Welcome names after the copy
  pass, and require complete Japanese catalogs.

- 2026-11-24: Add a display-only Finder storage bar over Finder's own status
  bar, shown only while Finder shows it. It reads volume capacity from the
  startup disk's resource values or the mount table, shows the selection count
  only, leaves the icon-size slider uncovered in icon view, and shares Finder
  Preview's tracker and selection poll (ADR 0076).

- 2026-11-24: Add Settings > General switches for automatic update checks and
  the menu-bar status item and its Recent block, all on. Reopening MacEase
  reaches Settings while the status item is hidden (ADR 0081).

- 2026-11-24: Add the Finder commands New File, Cut, Move Here, Copy Path and
  Open Terminal Here. Moves on one volume rename with Undo; moves to another
  volume copy, verify and keep the original (ADR 0080).

- 2026-11-24: Publish files exclusively through one step that falls back to an
  exclusive reservation and rename where `RENAME_EXCL` is unsupported, so new
  files and grouped outputs work on exFAT and FAT32 (ADR 0080).

- 2026-11-24: Replace fixed primary groups and Show at Top Level with a
  user-arranged menu per scope (Finder Menu, MacEase Menu, More, Hidden),
  menu.json schema 4 with ordered commands and a length-prefixed catalog hash,
  build-bound item tags, and a one-time migration of legacy placements
  (ADR 0079).

- 2026-11-24: Write the DMG install window as a `.DS_Store` without Finder
  scripting, over a pale designed background (ADR 0078).

- 2026-11-24: Open all media with external references forbidden through one
  constructor; QuickTime reference movies are refused everywhere (ADR 0077).

- 2026-11-24: Ask per file, per kind and per file version before leaving out
  content an output cannot carry, instead of refusing, in Activity, the editor,
  Audio Trim, Finishing Recipes and Audio Enhancement. Carry AVFoundation
  timecode natively in timing-preserving MOV outputs (ADR 0075).

- 2026-11-24: Replace Finder Preview's script and network toggles with three
  HTML states (Source, static view-only Preview, interactive with network),
  bound to the file version, with quarantine overriding Trusted Folders and a
  layered offline guard for static pages (ADR 0073).

- 2026-11-24: Make Finder Preview a setting-driven, content-only panel with a
  single top bar, per-kind viewers for text, HTML, Markdown, JSON, plists, SVG,
  fonts, images, audio, video and PDF, content identification, Find, and
  Settings > Finder Windows. Remove Information rows, folder totals, the action
  bar and text editing; old `text.edit` history remains undoable (ADR 0072).

- 2026-11-24: Add editor Save Frame, Freeze Frame and Reverse; reverse renders
  segments up to 60 seconds once into a staged intermediate and saves through
  the joined H.264 path (ADR 0071).

- 2026-11-24: Add editor markup (mosaic, blur and solid redaction; box, arrow
  and text) stored in source-canvas coordinates, with redaction rendered before
  geometry and annotations after colour (ADR 0070).

- 2026-11-24: Add editor Remove Silence and single-song background music with
  a fixed one-second end fade and stamp-checked saves.

- 2026-11-24: Use a 60,000 time scale for editor preview compositions so
  preview audio continues after cuts and replays.

- 2026-11-24: Require a solver-only QuickJS CLI without native I/O modules, with
  real capability-denial checks in builds and tests (ADR 0074).

- 2026-11-24: Strip debug/local symbols from media/audio helpers before signing,
  preserving executable sections and exports (ADR 0074).

- 2026-11-24: Omit Python GUI/bootstrap packages, certifi tests and bytecode
  caches while retaining runtime modules and source (ADR 0074).

- 2026-11-24: Replace Node with source-built QuickJS-NG 0.18.0, remove its JIT
  exception, and confine solver temporary files to request staging (ADR 0074).

- 2026-11-24: Enable Hardened Runtime with measured, per-executable exceptions
  and host Finder Automation access; preserve the unsandboxed host and
  self-signed, unnotarized distribution (ADR 0069).

- 2026-11-17: Request Finder Automation authorization before timed selection
  reads so the system consent dialog can remain open (ADR 0068).

- 2026-11-17: Add Finder Preview text editing with loaded-stamp Replace saves,
  original encoding/BOM and line endings, explicit UTF-8 confirmation, local
  buffer undo/find, Activity/Undo and dirty-buffer close/quit protection. Empty
  buffers remain prohibited by section 3.5. Extend unpublished ADR 0067.

- 2026-11-17: Redesign Finder Preview as a light, flush-docked panel with an
  always-visible close button, Show/Hide menu titles, outer-edge resizing,
  aspect-sized previews, Information rows and an icon action bar; fix the
  undocked window collapsing to its content's ideal size (ADR 0067).

- 2026-11-17: Extend Finder Preview with read-only text, web, structured-document,
  image, media and PDF viewers, bounded text decoding and opt-in HTML permissions
  (ADR 0067). Native execution remains unverified.

- 2026-11-17: Add authenticated Finder Preview, a docked host Quick Look panel
  with selection following, permission guidance and generic folder summaries
  (ADR 0067).

- 2026-11-17: Pin gallery-dl 1.32.20 and Node 26.13.1; yt-dlp 2026.10.26,
  HatchZip 0.1.10, FFmpeg 9.0.2, CPython 3.14.10 and OpenSSL 3.5.9 remain current.

- 2026-11-17: Remove saved photos from partially completed editor sessions,
  preserve remaining edits for retry after failure or cancellation, block editor
  shortcuts while saving, and deliver individual download outcomes immediately
  (ADR 0066).

- 2026-11-17: Keep the download window open with per-item status, Retry and a
  per-window destination; Return downloads listed results. Add M4A/MP3 quality.
  Keep the editor open while saving, move Reset All into Undo, separate export
  settings, use timecode and one speed control (ADR 0066).

- 2026-11-17: Add a blue Finder update item and one shared Update window with
  installation instructions and extension settings access (ADR 0065).

- 2026-11-17: Present successful results before secondary notes, keep notification
  notes count-only, and expose failure diagnostics in Activity Details with
  actionable localized headlines (ADR 0064).

- 2026-11-17: Add fixed primary Finder groups, More and group placement settings;
  remove legacy video Trim, Copy as Base64, Inspect Source and natural-language
  AI plans. Preserve historical Trim Undo and download provenance (ADR 0063).

- 2026-11-17: Declare one **MacEase…** Services item in Release builds only,
  keep the folder download item titled **yt-dlp…**, and record Quick Look preview limits (ADR 0062).

- 2026-11-17: Choose photo/video editor output mode per save through a split
  Save button, sharing one settings snapshot for naming and execution (ADR 0061).

- 2026-11-14: Run package acceptance suites sequentially without changing test
  assertions or their internal concurrency (ADR 0060).

- 2026-11-14: Update the isolated HatchZip core to 0.1.10, preserve the
  archive format scope and review current download runtime pins (ADR 0059).

- 2026-11-14: Dismiss completed Activity and notification results without
  affecting jobs, history, or Undo; repeat available-update notices daily and
  keep an update indicator in the menu bar (ADR 0058).

- 2026-11-05: Record implemented v3 toolkit limits, bundled model resources and
  license/source boundaries, gallery source records, QR HTTP lifetime, standard
  age protection and HatchZip 0.1.9. Keep integrated release acceptance pending
  and the ADR 0048 future VoiceOver exclusion unchanged (ADR 0057).

- 2026-11-05: Specify v3.0 acquisition, temporary local sharing, local enhancement,
  related-file discovery, encryption and authorized release delivery (ADR 0057).

- 2026-11-05: Copy native AAC and other non-Opus audio into Matroska with
  CodecDelay, DiscardPadding and the AAC core/SBR rates, and apply CodecDelay
  when decoding Matroska audio (ADR 0056).

- 2026-11-05: Add segment and audio-trim fades, video waveform lanes, loop and
  J/K/L shuttle playback, and yt-dlp link dropping, clipboard suggestions and
  thumbnails (ADR 0055).

- 2026-11-05: Decode HE-AAC tracks at their output layer, and give the photo/video
  editor, audio trim and download windows familiar editing layouts (ADR 0054).

- 2026-11-05: Preserve extracted audio, replace local MP3 encoding with an isolated
  LGPL executable, unify timeline interactions and harden downloads. Delivery is
  commit/push only, with no release publication (ADR 0053).

- 2026-11-05: Add isolated media downloads, measured two-second Activity and
  official-site update actions while retaining MIT and Apple Silicon (ADR 0052).

- 2026-11-02: Disable automatic Activity display by default and after reset,
  retaining manual access and existing saved choices (ADR 0051).
- 2026-11-02: Sign and verify the DMG container before computing its checksum,
  retaining the existing identity and unnotarized distribution (ADR 0050).
- 2026-11-02: Adopt owner-authorized balanced PNG target compression, using
  measured sizes for earlier downscaling, checking palette fidelity and falling
  back to full-color resizing instead of exhaustive maximum-effort searches
  (ADR 0049). Keep GIF dithering settings out of PNG processing.
- 2026-11-02: Accept observed resident memory around 1.56 GB, prioritize the
  requested few-second compression experience, and extend the VoiceOver scope
  exclusion to future work (ADR 0048).
- 2026-11-02: Remove VoiceOver support and verification from v2.1 scope at the
  owner's explicit request; preserve native labels and all other acceptance
  requirements (ADR 0047).
- 2026-11-02: Reuse lossless PNG filtering, preserve ordered results with
  bounded concurrent maximum-filter attempts, remove full-frame RGB copies
  and release mapped palette workspaces without changing quality or acceptance limits
  (ADR 0046).
- 2026-11-02: Approve v2.1 compression and UI stabilization, session-only image
  result comparison and failure-only retry, matched performance gates and
  three independent review rounds before publication (ADR 0045).
- 2026-11-02: Bound concurrent PNG palette candidates by the existing memory
  budget, release temporary buffers between scales, and correct premature
  palette truncation without changing resolution or selection priorities
  (ADR 0045).
- 2026-11-02: Reuse exact PNG pixels across lossless and palette attempts,
  avoid result-only raster copies and remove duplicate filter-zero row copies
  without changing decoded pixels or compression priorities (ADR 0045).
- 2026-11-02: Release PNG filter and compressed-output workspaces through
  scoped anonymous mappings, retaining only actual encoded bytes and keeping
  the existing memory budget (ADR 0045).
- 2026-11-02: Remove repeated static-PNG failure searches used only for a
  minimum-size estimate; retain verified target failure, original protection
  and editable retry without an invented minimum (ADR 0045).

- 2026-11-01: Record the owner's v2.0.0-only VoiceOver acceptance exclusion;
  actual reading/navigation remains unverified. The macOS 26 VM smoke check
  passed and is not excluded. Retain all other release gates (ADR 0044).

- 2026-11-01: Approve v2 automatic organization, batch photo editing,
  multi-source video editing, PDF page editing and finishing recipes, with
  durable move recovery, local classification, existing-data compatibility,
  measured optimization and three independent review rounds (ADR 0043).

- 2026-10-30: Extend the owner-approved VoiceOver and macOS 26 VM visual
  acceptance exclusions to v1.4.0. Both remain unverified; all other checks
  and tagged-source packaging remain required before publication (ADR 0042).

- 2026-10-30: Add immediate in-place HatchZip extraction with durable pause/resume
  and RAR-only ordinary extraction; reorder media menus. Add single-source segment
  splitting, deletion, duplication, reordering and per-segment settings, remove
  editor histograms/keyframe mode/ticks, and retain a prepared video surface
  (ADRs 0040 and 0041).

- 2026-10-30: Add the shared photo/video editor, direct manipulation, color and
  geometry processing, forced derived SDR for HDR color edits and v1.3.0
  acceptance/release requirements. Extend the explicit VoiceOver and macOS 26
  VM exclusions; both remain unverified (ADR 0039).

- 2026-10-28: Extend the owner-approved VoiceOver and macOS 26 VM visual
  acceptance exclusions to v1.2.0; retain unverified status (ADR 0038).

- 2026-10-28: Add low-resolution image/video presets, pitch-preserving video
  speed and combined editing, explicit Finder folder registration and a native
  Services fallback for iCloud-managed locations (ADR 0037). Release 1.2.0 is
  published locally after real-Mac checks and independent reviews; CI remains
  disabled.

- 2026-10-26: Exclude actual VoiceOver operation and the final macOS 26 VM
  visual check from v1.1.0 mandatory acceptance by owner instruction. Preserve
  their unverified status and the remaining local publication gates (ADR 0036).

- 2026-10-26: Add static-PNG SVG comparison and selective ZIP browsing with
  window-owned staging and snapshot-checked exports. Continue the approved
  local release validation policy for v1.1.0 (ADR 0035).

- 2026-10-23: Keep successful file warnings out of Activity problem counts,
  group repeated warnings, and retain file details (ADR 0034).

- 2026-10-23: Register mounted Finder volume roots explicitly and refresh on
  mount, unmount and rename; `/` alone misses separate volumes (ADR 0033).

- 2026-10-23: Replace whole-key natural JSON comparison with bounded,
  disk-backed ICU comparison while preserving existing ordering (ADR 0032).

- 2026-10-23: Accept Darwin kernel resident high-water measurements of the
  actual Release app when Instruments recording is unavailable (ADR 0031).

- 2026-10-23: Use the available M5/macOS 27 physical Mac and macOS 26 VM
  for v1.0.0 acceptance, as approved by the owner (ADR 0030).

- 2026-10-23: Stream JSON formatting and use external sorting without a total-file
  cap; preserve UTF-8 chunk-boundary U+FEFF (ADR 0029).

- 2026-10-23: Regenerate notices during DMG packaging and document local
  validation when hosted CI is unavailable or waived (ADR 0028).

- 2026-10-22: Adopt the Context Page icon family for the app icon, menu bar
  and Finder root glyph; add a menu bar attention state and per-state VoiceOver
  labels (ADR 0027).

- 2026-10-22: Ignore Matroska ENCODER, DURATION and statistics SimpleTags
  in metadata loss checks; user tags such as TITLE stay protected.

- 2026-10-22: Treat standard FLV onMetaData technical and encoder fields as
  regenerated so ordinary FLV files are not refused; user fields stay protected.

- 2026-10-22: Refuse INI global keys matching section names with the
  offending path before JSON or XML output.

- 2026-10-22: Apply signed padding across Matroska laces and preserve track
  enabled states through Matroska/WebM and native video outputs.

- 2026-10-22: Apply OpusHead output gain when decoding Matroska and WebM audio.

- 2026-10-22: Preserve exact Matroska lace timing; keep unresolved laces as
  continuations and refuse them inline only where a path needs timestamps.

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
  size steps down after a persistent miss,
  archive path checks replace `SECURE_NOABSOLUTEPATHS`, HEIC metadata strip
  re-encodes, MP3 below 128 kbps compresses to AAC,
  and the language switch asks first.
- 2026-10-21: Subtitles and Extract audio panels added; a bitrate chosen in the latter always re-encodes. The video
  Background panel offers the person and subject masks only.
- 2026-10-21: Video replace operations reject multiple video or audio tracks
  before writing so additional tracks cannot be lost (ADR 0010).
- 2026-10-21: Commit and undo stamps recorded (ADR 0011): scan checks before
  replace, bounded folder summaries, rename identity checks, safe skips for
  missing or incomplete stamps, and history retained after case-change failure.
- 2026-10-21: Undo shares commit serialization, refuses running batches and
  verifies Trash identity. Backup records save immediately, and normal quit
  waits for a sealed history flush (ADR 0011).
