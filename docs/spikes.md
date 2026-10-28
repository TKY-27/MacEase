# Spikes and Manual Verification

## Manual release checklist

Run against the release candidate on both macOS 26 and macOS 27, as required
by SPEC section 17. Record the commit, OS, hardware, and observed results in
the release review. Historical spikes below do not replace these checks.
For v1.0.0, the owner approved M5/macOS 27 physical acceptance supplemented
by the available macOS 26 VM; no M1 or macOS 26 physical results are claimed
(ADR 0030).

- Install from the signed DMG through the documented Gatekeeper flow. Confirm
  the app runs from Applications, onboarding completes, and Finder enables
  the extension. Verify nested menus, mixed selections, and catalog updates.
- Exercise the 5,000-path request, menu-file sandbox access, and cold launch.
  Check external and network volumes when validating Finder coverage.
- Use disposable inputs to check new-file and Replace modes, collisions,
  cancellation, partial failures, Trash identity, persistent history, and Undo.
- Check panels, Activity, notifications, settings, reopening, VoiceOver,
  larger text, light/dark appearance, Reduce Motion, Reduce Transparency, and
  Increase Contrast. Verify the performance targets in SPEC section 16.
- Complete HDR quality and metadata checks from SPEC section 8.12 with real
  gain-map captures and HDR/SDR displays.
- Install a second build signed with the same identity. Confirm privacy grants
  and Finder extension enablement survive.

Unavailable checks remain incomplete and block a stable release.
After publication, separately verify public update checks from a client
without GitHub authentication (CONTRIBUTING.md, Releasing step 6).

## v1.0.0 candidate verification (2026-10-23)

Environment: Apple M5, 24 GB, macOS 27.0.1 (26A434), Xcode 27.1,
Swift 6.4. The pre-publication checklist passes in the approved v1.0.0
environments below; anonymous published-asset checks follow publication.

### JSON memory and correctness

Measurements run the installed, self-signed Release app through its request
URL, JobEngine, staged output verification and final file commit. Each fixture
uses a disposable copy; source hashes remain unchanged. An independent checker
compares output SHA-256 against fixed expected bytes, including duplicate keys,
numeric spelling and ordering. MB and GB below are decimal.

| Fixture and operation | Input | Peak RSS | Elapsed |
| --- | --- | --- | --- |
| 50 million zero values, Pretty Print, previous implementation | 100 MB | 1,525–2,140 MB sampled | 7.0–7.6 s |
| Same dense array, streaming Pretty Print | 100 MB | 85 MB sampled | 10.1 s |
| 100 million zero values, Pretty Print | 200 MB | 72 MB sampled | 15.7 s |
| 400,000 padded records, Pretty Print | 206 MB | 56 MB sampled | 4.9 s |
| One long string, Minify | 400 MB | 49 MB sampled | 8.2 s |
| Two million object members, ordinal Sort Keys | 41 MB | 51 MB sampled | 37.3 s |
| Two 400 MB common-prefix keys, natural Sort Keys | 800 MB | 872 MB kernel high-water | 20.3 s |
| Two 900 MB common-prefix keys, natural Sort Keys | 1.8 GB | 845 MB kernel high-water | 61.0 s |
| Two base64-random keys, natural Sort Keys | 1.2 GB | 994 MB kernel high-water | 28.8 s |
| Two base64-random keys, natural Sort Keys | 2.4 GB | 1,396 MB kernel high-water | 62.6 s |
| Two base64-random keys, natural Sort Keys | 3.2 GB | 1,095 MB kernel high-water | 109.9 s |

Sampled RSS uses `ps` at 50 ms intervals and can miss peaks. Kernel high-water
values use `/usr/bin/time -l` around the actual app process, including startup.
Times measure request dispatch to committed output, not just parsing. Except
for the two previous-implementation runs, these are single observations on a
shared machine, not throughput comparisons. Random-key fixtures use Python's
seed 20261023 and base64-encoded 196,608-byte blocks, with first characters
`é` and `f`; common-prefix fixtures differ only at their final `A`/`Z`.

All listed streaming outputs pass the independent byte check. That natural
comparator still allocates two complete folded strings. The 2.4 GB and 3.2 GB fixtures
have peak physical footprints of 2.75 GB and 3.65 GB respectively; footprint
is not RSS. Resident measurements below 1.5 GB do not establish a bound for
arbitrary keys, particularly when compression and page reclamation can affect
residency. Those measurements did not establish the release gate (ADR 0029).

Instruments attach and launch recordings fail with `Failed starting ktrace
session`, including after Developer mode was enabled. Partial traces are not
accepted as evidence. `DevToolsSecurity -status` confirms Developer mode is
enabled; `ktrace info` also fails with `Too many levels of remote in path`.
The owner approved an equivalent official measurement method. Darwin
`getrusage(2)` defines `ru_maxrss` as maximum resident bytes; `/usr/bin/time -l`
reports this high-water mark after the actual host exits. The kernel rows
above include launch, request execution, verified commit and exit. They are
accepted measurements under ADR 0031, not a proof of bounded natural sorting.

The subsequent bounded comparator uses fixed caches and disk-backed UTF-16,
collation elements, numeric runs and canonical ordering (ADR 0032). The signed
Release executable SHA-256 is
`4f120d39562579087336a88a876dff6745e949572328c4dedf22a0118a421c11`.
The same full-app kernel harness measures launch through commit and exit.
These are single acceptance runs on the shared M5, not comparative speedups.

| Fixture and operation | Input | Peak RSS | Peak footprint | Elapsed |
| --- | --- | --- | --- | --- |
| Dense zero array, Pretty Print | 200 MB | 133.5 MB | 75.6 MB | 19.2 s |
| Base64-random keys, natural Sort Keys | 3.2 GB | 128.9 MB | 74.3 MB | 121.7 s |
| Secondary-weight keys, natural Sort Keys | 200 MB | 132.4 MB | 72.8 MB | 42.0 s |
| Long combining-mark prefixes, natural Sort Keys | 200 MB | 128.6 MB | 74.7 MB | 17.5 s |
| Non-ASCII numeric runs, natural Sort Keys | 200 MB | 139.7 MB | 77.2 MB | 9.5 s |

The secondary-weight pair starts with `a` plus grave/acute and then 100 million
`x` characters. The combining pair contains `a`, 50 million U+0315 marks and
one grave/acute mark. Numeric keys contain 50 million Arabic-Indic threes/twos.
Independent fixed-byte SHA-256 checks verify every complete output and unchanged
source. The largest comparator cache budget is 259 fixed 64 KiB pages, plus
fixed metadata and tables. Input-dependent comparison state spills to disk.
This source-level bound is separate from the measured resident peaks.

A Foundation-only witness exposes inconsistent comparison of long common
combining prefixes. Constructed and UTF-8-decoded strings have identical bytes
and UTF-16 units, yet their comparison direction can differ across representations
and processes. Complete UTF-16 CFStrings consistently agree with the bounded
comparator. A fixed regression checks both input orders and ascending/descending
output. ADR 0032 distinguishes the public-source defect from the untraced OS
machine code; unstable results are not preserved as an ordering contract.

### Platform and HDR checks

On the physical macOS 27 Mac, Finder's nested menu invokes HEIC-to-JPEG
conversion successfully. The final DMG-installed app retains the same catalog
version across three processes; a request created before shutdown succeeds
on cold launch with exact expected output and unchanged input. Canonical
metadata-set encoding fixes the previously unstable settings hash.
A real 12 MP capture containing both Apple and ISO
gain maps converts to SDR through the Release app in 0.90 s, at 236 MB sampled
RSS. The original remains unchanged. Output is upright, 3024 × 4032, 8-bit
Display P3, headroom 1, with neither gain map retained. Against ImageIO's SDR
reference at 512-pixel resolution, RGB mean absolute error is 1.46/255,
RMSE 1.69/255 and maximum error 13/255. These checks and inspected SDR previews
do not replace the required HDR/SDR display comparison. New-file and Replace
outputs were exercised on disposable copies. Activity's Undo removes four
new-file SDR outputs, which Finder shows in Trash, while every original hash
remains unchanged. Stopping a 1,000-copy HDR batch after 109 committed outputs
leaves all originals unchanged and no staged files. Activity's subsequent Undo
removes all 109 committed outputs. These checks use disposable copies only.

The owner compares that real capture and its SDR output side by side in
Preview on the built-in XDR display and reports no unnatural color cast or
highlight clipping in the white bag, desk or mouse. This is a human-observed
HDR-display result; screenshots do not measure HDR luminance. The owner
also reports no unnatural color cast, clipping or extreme brightness changes
in Apple Display (P3-600 nits) and Photography (P3-D65) SDR modes. The latter
reports EDR headroom 1.0. These are physical observations, not screenshot
measurements.

On macOS 26.6.2, ImageIO changes a valid ISO gain map's negative
`GainMapMin` to its positive magnitude during JPEG re-encoding. The same
input and probe preserve it on macOS 27. Changing the metadata value's
string or numeric representation does not avoid the macOS 26 defect.
Strict calibration verification correctly rejects the changed map. Image
resize, conversion and compression now retry this post-read failure as
SDR in new-file mode, with the existing warning; Replace still refuses
HDR loss. Decode, cancellation and I/O failures are not caught by this retry.
A synthetic two-color JPEG reproduces the calibration issue without private
image content. The 33 focused SDR, gain-map and compression tests pass,
including a deterministic fallback and original-preservation regression.
The updated signed Release app in the VM produces JPEG resize, HEIC
conversion and JPEG compression outputs from the affected real capture.
Activity displays the SDR warning. Independent ImageIO decoding confirms
headroom 1 and no retained gain maps; every source hash remains unchanged.
Repeating those three edits in Replace mode displays the HDR-loss refusal;
all original bytes and inodes remain intact, with no output committed.

The installed Release app also converts independently generated PQ and HLG
ramps through its normal request and commit path. The 16-bit PNG outputs
match CoreGraphics' reference-white SDR conversion exactly, retain 128
strictly increasing gray steps, have headroom 1 and contain no gain maps.
Main10 MOV inputs retain all 16 frames and their 0.1-second presentation
intervals. Their SDR HEVC outputs carry BT.709 primaries, transfer and matrix
tags. Against VTPixelTransfer's reference, maximum RGB error is 3/255 for PQ
and 2/255 for HLG; mean error is 1.16 and 0.56 respectively. Repeated-pattern
frame variation is at most 4/255 and 3/255, with no ramp-order violations.
Every source hash remains unchanged. These numerical checks do not substitute
for physical display acceptance.

On the physical Mac, Activity's Undo button removes a completed Pretty Print
output from a 50 MB dense JSON array while preserving the source SHA-256.
Finder shows the output in Trash; Put Back restores the same output inode
to its disposable test directory. No other Trash contents are changed.

Accessibility inspection finds that 12 settings toggles expose their detail
text without their visible title. Explicit labels and hints restore the
titles while retaining switch roles and values. The signed Release app's
accessibility tree verifies all 12 names; toggling progress off and on works.
Keyboard navigation reaches the progress switch and Space toggles it in both
directions. General and Text settings remain readable in light and dark
appearance and with Increase Contrast and Reduce Transparency enabled.
At the display's 1024 × 665 Larger Text setting, labels wrap without overlap,
and scrolling reaches the expanded JSON controls and final PDF options.
The original 1512 × 982 resolution and appearance settings are restored.
The owner verifies VoiceOver on the physical Mac: the menu-bar Settings
action opens settings, and the progress switch reads its name and on/off
state and can be toggled. This human verification supplements the automated
accessibility inspection; remote modifier-key forwarding did not provide
a reliable VoiceOver check in the VM.

The macOS 26.6.2 (25G83) VM installs the self-signed DMG, completes onboarding,
enables Finder Sync and performs JSON sorting with correct output and retained
input. The final candidate repeats the sort and signature checks successfully.
A same-certificate update preserves extension enablement. Through Apple
Screen Sharing, the menu-bar history Undo action moves the newly sorted
output to Trash and leaves the input SHA-256 unchanged. This verifies the
new-file UI Undo path in the VM. A separate Replace operation records the
exact original bytes and Trash backup inode, then restarts the host before
UI Undo. Undo restores those bytes and that backup inode, and removes the
backup from Trash. These checks do not prove physical display behavior or
Gatekeeper handling of a real browser download. A signature-verified copy
with an explicit quarantine attribute is rejected by Gatekeeper. After the
owner authorizes the VM-only exception, Settings → Privacy & Security →
Open Anyway and administrator authentication permit launch. Installing the
same copy into Applications then launches from `/Applications/MacEase.app`;
Gatekeeper assessments remain enabled. The published-asset download path
still requires verification after publication.

The VM image initially had SIP disabled. After enabling SIP in Recovery,
`csrutil status` and `spctl --status` confirm both protections are enabled.
Launching MacEase from Finder and converting a disposable Downloads file
then displays the actual macOS folder-access prompt. Allowing it records a
MacEase-specific Downloads grant. Installing the updated self-signed DMG
preserves that grant and Finder Sync enablement. A new Downloads conversion
succeeds without another prompt, with exact expected output and unchanged
source bytes. Earlier runs with SIP disabled are not privacy-grant evidence.

The physical Release host accepts one URL containing 5,000 distinct JSON
paths (200,153 URL bytes), commits 5,000 exact Minify outputs in 11.79 s,
and preserves every original byte. A second check selects all 5,000 originals
in Finder and invokes Minify through the extension menu. All 5,000 outputs
match and all originals remain unchanged; Finder retains focus. The 11.79 s
timing belongs to the Launch Services run, not the Finder run.

A batch of 1,000 disposable copies of a 12 MP JPEG produces 1,000 resized
outputs in 31.48 s. ImageIO fully decodes every output at 1512 × 2016; all
source hashes remain unchanged. The Settings window responds and changes
tabs during processing. A second batch with Reduce Motion enabled produces
1,000 resized HEIC outputs in 202.11 s, preserving every source hash. During
that batch, the owner confirms that the busy icon stays static and the menu
and Settings remain responsive. This is an interaction check, not a numeric
menu-bar latency measurement.

The benchmark fixture writer previously waited for video readiness before
feeding audio, allowing the two tracks to block one another. Independent
readiness and end-of-track notifications remove that cycle. The generated
60-second 1080p30 H.264/AAC fixture is 112,756,486 bytes, with a measured
14.88 Mbps video stream. An unprofiled Release benchmark compresses it to
18,582,646 bytes in 15.579 seconds. The installed Release app completes the
same input through its request and commit path in 16.928 seconds, producing
18,582,838 bytes. Independent decoding reads all 1,800 video frames and the
audio stream without errors; the source hash is unchanged. Both timings are
single acceptance observations on the shared M5. An earlier profiled run
took 79.815 seconds under heavier shared load and is not used for acceptance.
The initial complete benchmark measures the 1,000-item menu at 19 ms and 12 MP
HEIC-to-JPEG conversion at 291 ms, within their respective 30 ms and 500 ms
targets. These are M5 results, not M1 performance claims.

The final device-enabled package run passes 1,022 tests without skips:
44 MenuCatalog, 211 Formats and 767 Engine tests. Debug and Release builds,
strict lint and independent source reviews pass. The project-wide test audit
consolidates the malformed-container harness without dropping any of its
600 mutations, removes one redundant JSON flush test, and strengthens menu,
token, PNG, GIF, archive and extracted-PCM oracles. Focused before/after checks
and independent review find no lost proof. A cancellation test's short-lived
spool observation failed in the first full run. A longer multi-key fixture and
wall-clock deadline retain its cancellation, source-integrity and cleanup
assertions; both focused checks and the complete rerun pass.

Finder Sync initially omitted a separately mounted APFS volume when only
`/` was registered. Explicit mounted-root registration fixes the omission.
The signed Release extension invokes Sort Keys from Finder on that volume,
then again after rename, detach and reattach after extension startup. A
loopback WebDAV mount also exposes the menu and commits the exact expected
sorted bytes. Every source remains unchanged. These checks exercise mounted
APFS and macOS WebDAV paths, not physical USB hardware or a remote SMB server.

Activity previously counted successful SDR fallback notices as problems.
The signed Release now shows Done for 12 successful HDR resizes, with one
notice covering 12 files; Show All retains every filename. Mixed batches
report only the one actual skip or one truncated-image read failure, while
12 successful conversions remain separate. Explicit SDR conversion reports
Done without an automatic tone-mapping notice; its existing unknown-source-
provenance notice remains informational. All 40 valid source hashes remain
unchanged, and neither invalid input produces an output.

Location acceptance runs one operation for each of the ten concrete file
kinds (image, video, audio, PDF, document, plist, text, archive, JAR and folder).
On macOS 27, all 50 operations pass across Desktop, Documents, Downloads,
a separate APFS volume and iCloud Drive. The owner permits the protected
folder prompts; all source hashes remain unchanged. Output checks cover
image decoding, full audio/video decoding, PDF rotation, exact text/JSON,
archive contents, decompiled Java and the folder listing. iCloud reports the
output as ubiquitous, but account connection error 4355 prevents upload;
local provider access passes and remote synchronization is not claimed.
Only synthetic fixtures are used in iCloud Drive.

On macOS 26, all 40 corresponding operations pass across Desktop, Documents,
Downloads and a separate APFS volume. Desktop and Documents each show one
macOS permission prompt; the existing Downloads grant is reused. TCC records
all three as user-approved. Every source hash is unchanged; format/content
checks pass. The JAR check uses a separately installed OpenJDK 21 runtime.
The VM has no signed-in iCloud account; iCloud local-provider acceptance uses
the physical Mac. Separate volumes are APFS images, not physical USB devices.

For notification Undo, the owner presses Undo on the physical Mac's completed
JSON Replace notification. The restored file matches its original SHA-256
and the Trash inode recorded by the commit; persisted history marks the batch
undone. This supplements the automated Activity and VM menu-bar Undo checks.

CI remains excluded under the owner's billing decision and Actions stays
disabled. Anonymous download, published checksums and public update checking
are post-publication checks; their results belong to the release record.

## Finder Sync spike (2026-10-20)

Environment: macOS 27.0.1 (26A434), Apple Silicon, Xcode 27.1, Swift 6.4.
Minimal host app (`LSUIElement`, not sandboxed) with an embedded Finder Sync
extension (sandboxed), ad-hoc signed, built with XcodeGen.

| Question | Result |
| --- | --- |
| Does an ad-hoc signed Finder Sync extension load from `~/Applications` without quarantine? | Yes. `pluginkit -e use` enabled it and Finder spawned the extension process. |
| Does the item appear at the top level of the context menu? | Yes, as its own item (not inside Quick Actions). |
| How deep can submenus go? | Four levels verified (`Root ▸ L2 ▸ L3 ▸ L4`). Level 3 and 4 submenus may open to the left near the screen edge. |
| Do menu items keep `tag`? | Yes (`458755` round-tripped). |
| Do menu items keep `representedObject`? | No, it arrives as `nil`. |
| On which thread do action selectors run? | Off the main thread. Marking the extension class `@MainActor` crashed the extension with a libdispatch queue assertion when an item was chosen. Without it, Swift 6 mode builds and runs. |
| Does `NSWorkspace.open(urls, withApplicationAt:)` deliver files to the host? | No. LaunchServices was asked to launch, but `application(_:open:)` never received the files. |
| Does a custom URL scheme reach the host? | Yes, including from a cold start. |
| How large can the request URL be? | 5,000 paths (670 KB) with `&`, `#`, `%`, spaces and Japanese characters arrived intact. |
| Can the sandboxed extension read a host-written file? | Yes, with `com.apple.security.temporary-exception.files.home-relative-path.read-only` set to `/Library/Application Support/<folder>/`. |
| Multi-selection | `selectedItemURLs()` returned both selected files. |
| Replace flow | HEIC → PNG written, creation and modification dates copied, original moved to the Trash with `trashItem`. |
| Duplicate registrations | A second copy of the same bundle ID produced a duplicate menu item. Debug builds must use a different bundle ID. |
| Quarantined download | `spctl` rejects the ad-hoc app; launching it runs from an App Translocation path and the extension is not registered until quarantine is cleared. |

## Trim panel prefill (2026-10-21)

Environment: macOS 27, Debug host, 301 s H.264 + AAC test clips.

| Question | Result |
| --- | --- |
| Does `AVPlayerView.beginTrimming` accept a range set on the item before it starts? | The handles show it, but the Trim button stays disabled until the user moves a handle. Setting `reversePlaybackEndTime` and `forwardPlaybackEndTime` right after trimming begins moves the handles and enables Trim. |
| Does a trim ending exactly at 300 s stay within 300 s? | No. A keyframe-mode MKV trim ended at 300.6 s and an exact-mode trim at 300.001 s (audio frame granularity), so LINE's Trim prefill ends one second early. |

## HDR auxiliary images (2026-10-21)

Environment: macOS 27.0.1 (26A434), Apple Silicon, Xcode 27.1.

| Question | Result |
| --- | --- |
| What does Core Image's `hdrImage` representation generate? | ISO gain maps with `L008` samples and nested `HDRToneMap:ChannelMetadata`, for JPEG and HEIC. |
| What does an explicit `hdrGainMapImage` generate? | Apple monochrome gain maps with `HDRGainMap:HDRGainMapVersion`, for JPEG and HEIC. |
| Why did all four original JPEG geometry tests refuse replacement? | Post-encode `CFEqual` on the nested metadata-tag array reported inequality despite identical calibration values. Recursive value comparison makes the four cases pass. |
| Does ImageIO return RGB ISO raster bytes? | For generated `hdrGainMapAsRGB` files it returns `420f` descriptions and metadata, but omits `kCGImageAuxiliaryDataInfoData`. Core Image's `auxiliaryHDRGainMap` option decodes the image. |
| Which RGB auxiliary input does ImageIO write? | Packed `24RGB` finalizes for JPEG and HEIC. `32RGBA` fails finalization. Both were tested with the original ISO calibration and color space. |
| Are pointwise RGB comparisons stable after resizing? | No. RGB ISO re-encoding produced 20–21 levels of error at a color edge, while surrounding errors were smaller. Verification keeps the 16-level threshold over 3-by-3 mean absolute RGB errors; monochrome remains pointwise. |

## Document conversion boundaries (2026-10-21)

Environment: macOS 27.0.1 (26A434), Apple Silicon, Swift 6.4, macOS 26 target.
Verified with generated fixtures in the package's document and plist tests.

| Question | Result |
| --- | --- |
| Does a WebKit content rule blocking every URL also block data-URL stylesheets? | No. A data-URL stylesheet still hid the test text. A response Content Security Policy allowing only the custom local scheme blocked it while local CSS continued working. |
| Does disabling page JavaScript still allow host text extraction? | Yes. Inline page scripts did not change the text; host `evaluateJavaScript` returned the visible UTF-8 body text. |
| Does XML plist serialization retain fractional dates? | No. Binary output retained milliseconds; XML truncated them. The conversion compares typed values after serialization and rejects that loss. |
| Can `CFEqual` validate Boolean and numeric distinctions? | No. It equates NSNumber representations of true, 1, and 1.0. Typed canonical JSON comparisons preserve the distinction. |
| Are PDF thumbnail color thresholds independent of profiles? | No. The fixture's green component became 0.343 after thumbnail-to-deviceRGB conversion. Direct CGPDF drawing into an explicit sRGB RGBA bitmap retained 576 red samples under the unchanged thresholds. |

## Native media conversion boundaries (2026-10-21)

Environment: macOS 27.0.1 (26A434), Apple Silicon, Swift 6.4.
Generated fixtures run through package operations and native decoders.

| Question | Result |
| --- | --- |
| Can ImageIO decode and encode PSD and TGA here? | Both identifiers are advertised. Generated PSD composites export to PNG/JPEG/TIFF; PNG and TIFF retain decoded pixels. TGA-to-PNG round trips retain decoded pixels. This is not macOS 26 device proof. |
| Does the GIF loop property equal the Netscape field? | No. ImageIO reports total plays for finite GIFs; the stored field counts repeats after the first play. Writing the property directly into that field adds one play. Zero remains infinite; one play omits the extension. |
| Can PDFKit and ImageIO stage every PDF page into TIFF? | Yes. Two generated black/white pages retain their order, dimensions, and 144 dpi metadata. The aggregate raster budget refuses an oversized page before creating output. |
| Does the existing decoder accept AIFF-C PCM? | Yes. A generated `AIFC`/`NONE` fixture decodes the expected channels, rate, and samples; staged CAF PCM conversion retains samples exactly. An unknown compression code fails before output. |
| Which checks remain blocked here? | Final commits fail with Cocoa 256/512 under the sandbox. An independent Foundation-only probe coordinating two `/tmp` files reproduces both errors. Core Image resize fails rendering. ALAC encoders are absent from `afconvert -hf`; M4A ALAC rejects settings and CAF ALAC returns format error 1718449215. Existing lossless audio coverage also aborts with that format error. GIF quality fixtures cannot encode their H.264 source video (`-11834`). No tests are skipped for these failures. |

## TOML ownership (2026-10-21)

Environment: macOS 27.0.1 (26A434), arm64, Swift 6.4, macOS 26 target.

| Question | Result |
| --- | --- |
| Does the old TOMLKit path retain allocations across conversions? | Yes. After eight warmup conversions, forty conversions of a 512 KiB payload grew resident memory by 44,728,320 bytes when parsing and 66,306,048 bytes when writing. Both failed the unchanged 16 MiB allowance. This was one filtered Debug test run. |
| Does the owned toml++ bridge pass the regression? | Yes. Parsing, writing, and rejected partial conversions pass the same forty-iteration, 16 MiB growth checks. Final tests use separate Swift Testing child processes, autorelease pools, and `mach task_info` resident size. This checks cumulative growth, not peak usage or every possible leak. |
| Are existing conversion contracts preserved? | All 24 YAML/TOML tests pass, including seven added cases for nested local/offset dates, empty structures, escaped keys, NUL refusal, byte/value limits, and a 20,000-key table. |
| Is vendored provenance enforced? | The copied header matches SHA-256 `6b5172ad4dd6519aec67b919181fa7a38a2234131e5b2afa232dfe444819783e`. Notice generation includes its MIT license once and excludes the TOMLKit wrapper notice. A modified header in a temporary fixture fails before output. |

Commands: `swift build --package-path Packages/MacEaseKit`,
`swift test --package-path Packages/MacEaseKit --filter TOMLConversionTests`,
`swift test --package-path Packages/MacEaseKit --filter TOMLConversionMemoryTests --quiet`,
and `make lint` pass. macOS 26 runtime, full-package tests, upstream compliance
suites, app GUI, and release binary-size comparisons were not run.

## Memory and storage measurements (2026-10-21)

Environment: Apple M5, 24 GB, macOS 27.0.1 (26A434), Xcode 27.1, shared
machine (timings vary by up to 3×; memory is stable across runs). Each item
ran alone through `scripts/bench.sh <operation> <file> [preset]` under
`/usr/bin/time -l`; values are peak memory footprint. Generated fixtures: 4K
HEIC, 48 MP JPEG, 60 s 1080p H.264 15 Mbps MP4 and MKV, 30 s clip, 20 s 4K
HDR10 HEVC, 300-frame 800×450 GIF, 200-page PDF, 1 GB folder and its 539 MB
zip, 2 h Opus, 400 MB UTF-8 log, 200 MB JSON.

| Item | Before | After |
| --- | --- | --- |
| 4K HEIC resize 50%, 48 MP JPEG → HEIC | 172 MB, 410 MB | unchanged |
| 1080p 60 s compress, 30 s to GIF, GIF resize | 111, 83, 72 MB | unchanged |
| 200-page PDF to PNG, 1 GB zip extract, 4K HDR10 to SDR | 34, 7, 186 MB | unchanged |
| SHA-256 of a 539 MB file | 522 MB | 8 MB |
| Compress a 1 GB folder to zip | 1,038 MB | 10 MB |
| 2 h Opus → AAC | 143 MB | 26 MB |
| 1080p MKV → MP4 (remux) | 118–336 MB, 4–5 s | 25–32 MB, 0.6 s |
| 400 MB UTF-8 text to CRLF | 2.0–2.4 GB | 1.2–1.6 GB |
| 400 MB UTF-8 text to UTF-16 | 3.2–3.9 GB, 16–21 s | 1.8–2.0 GB, 3–4 s |
| 40 MB UTF-16 text to CRLF | 340 MB | 195 MB |
| 200 MB JSON pretty-print | 2.5 GB | unchanged |
| Images to PDF, six / twelve distinct 12 MP photos | 264 MB / refused (`frameMemoryExceeded`) | 141 MB / 194 MB |

| Question | Result |
| --- | --- |
| Why did chunked reads hold whole files? | `FileHandle.read(upToCount:)` returns autoreleased buffers; a loop inside one task never drained them. Reading inside `autoreleasepool` keeps memory flat. Outputs were byte-identical, or identical in packets and zip CRCs where container timestamps differ. |
| Where did text conversions peak? | Decoded text kept alive during conversion, an `Array(data)` copy, result regrowth, and per-unit arrays when writing UTF-16. Outputs stayed byte-identical on UTF-8, UTF-16 LE/BE and Shift_JIS fixtures with mixed CR, LF and CRLF. |
| Idle host (isolated Release build, own support folder) | 15 MB footprint after launch. After twelve batches including the text and folder items: 283 MB before, 44 MB after, 60 s later. Idle CPU 0.03–0.1%. `leaks` reports about 415 system-framework objects (20 KB) in both builds. |
| Release bundle | Archived app 21.9 MB; executable 19.0 MB, already stripped and dead-stripped. Native codecs are 14.4 MB of it, Swift 4.7 MB, `cfr.jar` 2.1 MB. DMG: UDZO 11.9 MB, ULFO 11.2 MB, ULMO 8.8 MB. |
| History writes | Each Trash-backed record rewrites the whole `history.json`: 1,000 removals took 3 s and wrote about 118 MB; 3,000 took 17 s and about 1 GB. |
| Temporary files | Each benchmark run left its sparse image folder and support folders; Formats tests left about 11 files per run (714 files, 16 MB found). |

## HDR video edit lists (2026-10-22)

Environment: macOS 27.0.1, Apple Silicon, FFmpeg 9.0.2 with x265.

| Question | Result |
| --- | --- |
| Why did x265 HLG/PQ MOV and MP4 files refuse SDR conversion? | FFmpeg writes an edit list that starts the media at the B-frame delay (1024/12288 s for 24 fps). Passthrough `AVAssetReaderTrackOutput` samples keep media presentation times, while decoded frames use edited track times, so no packet duration matched the first frame. |
| Which edit lists can SDR conversion map? | Non-empty segments at rate 1 that share one media-to-track offset. Empty edits and scaled edits still refuse with `hdrConversionUnsupported`. |
| Does AVFoundation read in-band HDR10 SEI? | Yes. x265 mastering display and content light level SEI appear as `MasteringDisplayColorVolume` and `ContentLightLevelInfo` format extensions in MP4. |
| Can SDR conversion read Matroska HEVC? | No. `AVURLAsset` reports "Cannot Open" for MKV before classification. |

## Release checklist (manual, run on macOS 26.x and 27.x)

1. Install the DMG on a clean user account, clear quarantine with Open Anyway,
   enable the extension from onboarding.
2. Check the menu at all four levels for single-kind and mixed selections, and
   the container menu on a folder background.
3. Run one operation per kind on Desktop, Documents, Downloads, an external
   volume and an iCloud Drive folder; confirm protected locations request
   access when needed and reuse granted permissions.
4. Send a 5,000-file selection and confirm the batch starts.
5. Install the next build over it and confirm TCC grants and the extension's
   enabled state survive.
6. Undo a replace batch from the notification and from the menu bar.
7. Run `scripts/bench.sh` and record results in the release notes.

## Streaming text and eager-input memory (2026-10-22)

Environment: Apple M5, macOS 27.0.1, Swift 6.4, shared machine under high load.
Standalone Swift executables compile the production conversion sources with
`-O -whole-module-optimization -swift-version 6 -warnings-as-errors`.
Minimal type stubs replace unrelated engine settings and errors. Timed text
work includes input reading, conversion, staged writing and text verification.
It excludes the host, JobEngine, unchanged-file comparison and final commit.
Input files are generated, never memory-mapped. Baseline verification maps
only its own staged output; the new verifier streams it.

`/usr/bin/time -l` prints elapsed time but cannot obtain `kern.clockrate` under
this sandbox. Maximum resident size below comes from `getrusage(RUSAGE_SELF)`
inside the executable, in bytes, converted to decimal MB. These RSS values
are not the peak-footprint measurements in the earlier table.

| Workload | Before maximum RSS | After maximum RSS | Runs per side |
| --- | --- | --- | --- |
| Read 200 MB through EncodedImageInput | 407.45 MB | 209.40 MB | 1 |
| 400 MB UTF-8 to UTF-16 | 1,616 MB | 7.70 MB | 1 |
| 400 MB UTF-8 to CRLF | 1,050–1,600 MB | 8.13–8.16 MB | 5 interleaved pairs |
| 200 MB JSON records to pretty JSON | 1,186 MB | 917 MB | 1 |

The text fixture repeats `aa\rB\nc\r\nd\n` to exactly 400,000,000
bytes. UTF-16 output is 800,000,002 bytes including the BOM; CRLF output is
520,000,000 bytes. The JSON fixture is an array of 400,000 records with short
keys and padded string values, totaling 200,000,000 bytes.
The eager-input fixture is a compact JSON object with one `payload` string
containing 199,999,986 ASCII `x` bytes, totaling 200,000,000 bytes. This measures
opaque encoded-input reading, not image decoding. The timed region hashes
every returned byte so lazy page residency cannot hide a copy.
Every before/after output hash matches; an independent fixture checker
verifies the text outputs and parses the JSON records.

CRLF elapsed medians are 3.43 s before and 1.85 s after, with ranges
3.33–4.18 s and 1.62–2.21 s. Single UTF-16 times are 3.61 s and 3.43 s;
single JSON times are 4.57 s and 4.00 s. Shared-machine load and single runs
limit timing conclusions. A preliminary executable without whole-module
optimization measured a large normalization slowdown; it does not represent
the production Release configuration and is excluded from these comparisons.

The text path retains only bounded chunks, while eager image input still
retains its required payload. JSON streams output but retains decoded input,
parser bytes and its value tree. Its result depends on document structure;
this fixture does not establish arbitrary-JSON or full-app 1.5 GB acceptance.
The existing total-file input policies are unchanged. Shift_JIS alone refuses
a single grapheme above 1 MiB, preserving per-character replacement behavior
without unbounded combining-sequence retention (ADR 0021).

Focused Swift Testing coverage checks five source encodings, multibyte and
CRLF boundaries, BOM precedence, ambiguity, replacement policies and line
numbers, incomplete input, cancellation, the grapheme guard, staged bytes,
output verification and unchanged skips. Real child-process exit tests in
both test targets verify registered support-folder removal, including duplicate
registration. PlanningTests (23 tests) and ArchiveExtractorTests (5 tests) also
leave no new matching support or scratch directories after process exit.
The full test run, app GUI and full-app Instruments measurements are not run.

## Native audio packet copying (2026-10-22)

The existing `ffmpeg-h264-aac.mp4` fixture has a 1024-sample AAC edit at
48 kHz and 96,000 audible frames. Rebuilding its compressed sample buffers
without their propagating attachments makes AVAssetWriter choose its default
2112-sample priming. Restoring only the public trim keys and output timestamps
does not preserve this source edit. Copying the opaque attachment dictionary
with CoreMedia's public copy/set APIs does; no private key names are needed.
Splitting a buffer still requires recalculating each packet's leading trim,
trailing trim, and output presentation timestamp after restoring attachments.

A standalone native remux using the production Formats sources preserves the
1024-sample edit and two-second presentation range. Independently decoding
source and output with the installed FFmpeg produces 96,000 frames each,
with identical PCM hashes and the first audible frame at index 2. A native
350–1350 ms range copy produces 48,000 decoded frames and a one-second edit.
The source reader returns required preroll before the requested start and a
final packet whose raw PTS exceeds the requested end; its output PTS remains
inside the range. Packet selection must retain those samples.

For HDR coverage, preserving the original AAC track in AVMutableMovie while
replacing its video with `x265-hlg.mov` retains non-default priming. Inserting
AAC into a fresh movie instead normalizes its priming to 2112 samples. Adding
a 250 ms empty edit to the retained audio track preserves its 1024-sample edit;
the standalone native remux also preserves this offset and its audible length.

Formats compiles with Swift 6 and warnings as errors, and the focused Swift
Testing sources type-check. Full package builds and focused test execution
remain blocked by `sandbox-exec: sandbox_apply: Operation not permitted`.
Native AVAssetReader PCM decoding also fails with AVFoundation `-11800` in
this sandbox. These probes do not establish full Transcoder re-encode or
HDR-to-SDR runtime acceptance; their regression tests require a permitted Mac.

### Container-specific follow-up (2026-10-22)

On macOS 27.0.1 with Swift 6.4, the existing MKV keyframe-trim test reproduces
a negative first audio timestamp. The source reader selects the 0.5-second
video keyframe for the requested 0.7-second start. Its first audio buffer has
raw PTS 0.490666667 s, output PTS 0.5 s, and 0.030666667 s of leading trim
across two AAC packets. The next complete audio packet starts at presentation
time 0.512 s. Whole-packet presentation timing avoids a negative start or
overlapping partial packets in containers without edit lists.

After the container-specific copy fix, `TranscoderTests` and
`AudioCopyTimingTests` pass all 19 tests, including their parameterized cases.
The original MKV expectation remains `0 <= firstAudio < 25 ms`. Native remux,
video re-encode, HDR-to-SDR, extraction, and sample-accurate audio trim checks
pass. Added checks compare decoded onset after a 250 ms audio edit in MKV,
FLV, and native PCM copied into AVI, and verify Opus CodecDelay, SeekPreRoll,
CodecPrivate, and packet timestamps after WebM-to-Matroska copying.

The focused command uses `swift test --package-path Packages/MacEaseKit`
with `--filter 'TranscoderTests|AudioCopyTimingTests'`, `--disable-sandbox`,
`--disable-automatic-resolution`, and writable temporary SwiftPM cache,
configuration, and security directories. SwiftPM's nested sandbox otherwise
fails with `sandbox_apply: Operation not permitted`. Package compilation treats
warnings as errors. `make lint` passes. The full suite and app GUI are not run.

## SVG preparation and selective ZIP reads (2026-10-26)

Release engine measurements on Apple M5 (10 cores), macOS 27.0.1 (26A434),
use five interleaved runs per comparison. Two synthetic PNGs produce identical
SVG bytes before and after the feature work: 2,817 bytes for the 256-pixel logo
and 41,649 bytes for the 1,024-pixel shapes fixture. Standard conversion
medians are 19/19 ms and 82/85 ms before/after, with overlapping ranges; no
SVG conversion speedup is established. Dedicated in-memory preparation takes
11.0 ms and 76.3 ms, with process peak RSS of 23.9 MB and 45.3 MB. Its timer
excludes the UI renderer and save commit, so it is not a conversion comparison.

The stored ZIP fixture has 1,026 entries: one unselected 128 MiB member,
one selected 34-byte text file, and 1,024 empty metadata files. Median listing,
first selected preview and close times are 9.5 ms, 6.2 ms and 0.6 ms, sharing
a process peak RSS of 19.0 MB. Each run verifies that listing creates no staging
content, preview materializes only the selected member, close removes staging,
and the closed session refuses reuse.

Exporting the 1,024 empty members through Derived commit takes 1.966 s
(1.939–2.082 s) with repeated readers and 0.105 s (0.104–0.121 s) with one
reader: 18.7 times faster for this fixture. Peak RSS remains about 22.4 MB.
An independent untimed sample identifies repeated archive-header traversal
as the previous limiter. Exact output paths and zero lengths match in every
run. This does not establish a speedup for single-member or large-payload
exports. File/code caches are warm and background GUI services remain active.
The 45 valid samples succeed; an initial relocated-binary resource-bundle
setup failure is retained and excluded before any engine measurement.

The seekable reader in pinned libarchive 3.8.10 scans the last 16 KiB for the
last complete EOCD signature without validating its comment length. Bounded
preflight must select that same signature before validating the directory;
choosing an earlier record with a matching comment length is inconsistent.
Small comment fixtures verify rejection of ambiguous tails and of ZIP64
locators outside the reader's visible tail. Disable mac-ext processing to
list AppleDouble entries explicitly and avoid hidden content reads.

## Finder Services and playback-speed timing (2026-10-28)

On this Mac, the enabled v1.1.0 Finder Sync extension appears for local
Downloads and temporary folders but not for iCloud-managed Desktop and
Documents. Root registration alone does not make those menus appear. The
Services fallback is therefore required alongside explicit directory registration.
Finder supplies `NSFilenamesPboardType` on this system: declaring only
`NSSendFileTypes` invoked the service without readable NSURL objects. Declaring
file-URL and legacy filename pasteboard types, and reading either representation,
lets the same selection enter the host operation chooser. `NSRestricted` remains
enabled; macOS may ask the user to confirm the service.

Native AAC passthrough produced a 2,112-frame priming offset at 48 kHz when
independently decoded by ffmpeg, although AVFoundation compensated for it.
Passing Float PCM to the final AVAssetWriter AAC input instead emits standard
trim timing. External decoding of actual app outputs then measured approximately
440 Hz and a maximum 8.34 ms audio/video marker difference across MOV, MKV,
WebM, AVI and FLV at 2x. The fixture contains three audiovisual amplitude markers
at 60 fps; the acceptance limit is 20 ms here, and pitch error is at most 1%.

FLV has millisecond timestamps. Without declaring that timestamp quantum,
PCM continuity inserted and removed fractional packet samples, raising the
440 Hz tone to about 450 Hz. Propagating a 1 ms quantum preserves contiguous
PCM. Repeating the independent measurement gives 440.008 Hz and at most
6.31 ms marker error. A separate Matroska fixture with missing audio packets
from about 1.0 to 1.5 seconds retains its silence and subsequent markers at 2x.

Native six-channel decoding can return AAC speaker order rather than canonical
MPEG speaker order. Speed changes currently refuse audio layouts beyond mono
and stereo instead of relabeling or downmixing them. Supporting those layouts
requires carrying explicit speaker layout through PCM normalization.

A ten-minute 128x96, 1 fps video with continuous 48 kHz audio became exactly
five minutes at 2x for both tracks. The development app's sampled RSS increased
from 98.5 MiB to a peak 130.1 MiB, rather than retaining the 109.9 MiB PCM source
in memory. This is one observation with a warm app, not a general memory bound.

The signed v1.2.0 app retained the v1.1.0 certificate and existing Desktop,
Documents, Downloads and iCloud permission switches. Nevertheless, initial
cloud reads blocked inside NSFileCoordinator's protected open. Selecting the
specific QA folders in NSOpenPanel restored access; after a complete app
restart their bookmarks resolved and both access checks returned Readable.
Finder Services then wrote 480x270 on Desktop and in Documents, including
a collision-numbered output after restart. Downloads' normal Finder Sync
menu wrote 360x203. No Full Disk Access or TCC reset was used. The OS wait
is not forcibly interrupted; Settings documents explicit folder selection
and app restart as recovery.

A folder bookmark followed a renamed QA directory, reported denied after
permissions were removed, and returned to Readable after they were restored.
Removing its list entry retained the directory. A read-only mounted DMG was
registered, detached, shown as Unavailable, and removed from the list without
remounting it. Welcome's Add Folder and the Files and Folders settings link
were exercised on the signed app.

An 8 kHz human-speech fixture exposed an unsupported AAC bitrate in the native
PCM writer path. Reusing the existing nearest supported bitrate selection
fixes 8, 16 and 22.05 kHz inputs; regression checks preserve the 440 Hz pitch
within 1% and the two-second duration within 20 ms. Speech material is from
the [Open Speech Repository](https://www.voiptroubleshooter.com/open_speech/american.html),
OSR_us_000_0010_8k.wav; it is used for local testing, not bundled with MacEase.
