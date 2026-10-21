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
