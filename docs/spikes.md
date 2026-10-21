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
