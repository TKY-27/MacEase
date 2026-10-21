# Spikes and Manual Verification

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

| Question | Result |
| --- | --- |
| Why did chunked reads hold whole files? | `FileHandle.read(upToCount:)` returns autoreleased buffers; a loop inside one task never drained them. Reading inside `autoreleasepool` keeps memory flat. Outputs were byte-identical, or identical in packets and zip CRCs where container timestamps differ. |
| Where did text conversions peak? | Decoded text kept alive during conversion, an `Array(data)` copy, result regrowth, and per-unit arrays when writing UTF-16. Outputs stayed byte-identical on UTF-8, UTF-16 LE/BE and Shift_JIS fixtures with mixed CR, LF and CRLF. |
| Idle host (isolated Release build, own support folder) | 15 MB footprint after launch. After twelve batches including the text and folder items: 283 MB before, 44 MB after, 60 s later. Idle CPU 0.03–0.1%. `leaks` reports about 415 system-framework objects (20 KB) in both builds. |
| Release bundle | Archived app 21.9 MB; executable 19.0 MB, already stripped and dead-stripped. Native codecs are 14.4 MB of it, Swift 4.7 MB, `cfr.jar` 2.1 MB. DMG: UDZO 11.9 MB, ULFO 11.2 MB, ULMO 8.8 MB. |
| History writes | Each Trash-backed record rewrites the whole `history.json`: 1,000 removals took 3 s and wrote about 118 MB; 3,000 took 17 s and about 1 GB. |
| Temporary files | Each benchmark run left its sparse image folder and support folders; Formats tests left about 11 files per run (714 files, 16 MB found). |

## Release checklist (manual, run on macOS 26.x and 27.x)

1. Install the DMG on a clean user account, clear quarantine with Open Anyway,
   enable the extension from onboarding.
2. Check the menu at all four levels for single-kind and mixed selections, and
   the container menu on a folder background.
3. Run one operation per kind on Desktop, Documents, Downloads, an external
   volume and an iCloud Drive folder; confirm TCC prompts appear once per
   location.
4. Send a 5,000-file selection and confirm the batch starts.
5. Install the next build over it and confirm TCC grants and the extension's
   enabled state survive.
6. Undo a replace batch from the notification and from the menu bar.
7. Run `scripts/bench.sh` and record results in the release notes.
