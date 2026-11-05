# Audio and editing stabilization validation

This is unreleased work following v2.2.0. The owner requested commits and a push
only: no tag, GitHub Release, DMG publication or production website deployment.
The existing version, signing policy and disabled Actions remain unchanged.

## Findings and changes

- Four November 5 crash reports identify Swift exclusive-access violations in
  the editor's `change` mutation and `sourceFrameDuration` read. Edits now mutate
  a local copy before assigning observable state. App-hosted tests exercise the
  actual model, rather than treating package geometry tests as crash proof.
- Local MP3 output previously used the independent Swift encoder. A comparison
  on available music found lower decoded quality than LAME, without an automatic
  normalization step. The exact video reported by the owner is unavailable, so
  its audible symptom is not established as reproduced. Local MP3 now streams
  PCM into the pinned isolated FFmpeg/libmp3lame process.
- Original extraction uses the existing codec-copy paths, with explicit refusal
  when a compatible container or representable timing is unavailable. AAC
  compressed payloads and decoded samples are compared against the source.
- The supplied TikTok URL resolves to 1080 × 1400 video. The downloaded MP4
  contains 590 valid video packets, 460 audio packets and 3,343 empty H.264 tail
  packets. The narrow repair preserves valid payloads, presentation/decode times,
  durations and audio skip/discard information. Strict decoding still runs;
  other corruption is rejected. Provider availability can change independently.
- Missing HLS fragments could previously yield a shorter successful download.
  An actual local HTTP fixture now proves failure, no committed output and no
  history entry when a middle fragment is missing.
- CSV duplicate headers discarded fields in object conversion. JSON/XML output
  now refuses ambiguous headers; tabular HTML/Markdown remain valid. JSON-to-CSV
  now emits the specified UTF-8 BOM, including for Japanese text.

## Operation audit ledger

“Read” describes source inspection, not a claim of complete device coverage.
Destructive and commit-boundary tests use disposable inputs and isolated history.

| Operations | Intended change / retained content | Existing independent proof | Audit result |
| --- | --- | --- | --- |
| Image conversion/compression/geometry/background | Requested format, size or geometry; precision, color, alpha and supported metadata | Image precision, metadata, compression and geometry suites | Read; no additional confirmed material defect |
| Photo editing, multi-selection, export/icon/OCR/Base64 | Explicit edits or derived output; original identities and per-source policy | Editor, source-stamp, export, icon, OCR and Base64 suites | Read; UI coverage recorded separately |
| Video conversion/editing/trim/speed/join | Explicit changes; track safety, timing and source mapping | Transcode, video edit, timeline, precision and preservation suites | Trim exclusivity defect fixed; hosted model proof added |
| Audio extraction/convert/compress/trim/normalize | Only requested codec/range/loudness changes | PCM identity, independent AudioToolbox decode, channel, metadata and loudness tests | MP3 route replaced; original-copy operation added; unsupported tag loss guarded |
| PDF conversion/editing/merge/split/crop | Requested pages and geometry; links/forms/outlines where supported | PDF suites and PDFKit crop-origin/quarter-turn probe | Read; no additional confirmed material defect |
| Text/documents/plist/YAML/TOML | Requested representation; values and encoding contract | Round-trip, malformed-input, parser-limit and conversion tests | Two CSV defects fixed |
| Archives/HatchZip/ZIP browsing | Explicit extraction; path, identity, quota, recovery and source rules | Archive/HatchZip safety, manifest and recovery suites | Read; no additional confirmed material defect |
| Folder organization | Requested moves; identity, collision, rollback and Undo | Organizer, volume, journal and recovery suites | Read; watcher/UI combinations not exhaustively exercised |
| Downloads | Selected source streams and subtitles; complete media and collision safety | Process, playlist, identity, retry and integration tests | Resolution display, missing fragments and narrow TikTok repair corrected |
| Recipes/settings/history/Undo | Recorded requested settings; source stamps and atomic commit | Recipe, settings, commit, recovery and history suites | Read; no additional confirmed material defect |

## Test preservation

The old MP3 bitstream implementation is removed. Its independent decoder,
stereo-channel, tail, VBR-size, silence and 192 kbps quality/bandwidth assertions
remain against the public `AudioFileEncoder` output. MPEG frame parsing uses the
standard bitrate table independently of the encoder. The 20 dB music criterion
and 16 kHz bandwidth threshold are unchanged. Additional clipped stereo,
cancellation and occupied-output tests cover the replacement process. Short CBR
and VBR boundary cases preserve exact decoded lengths in both AudioToolbox and
FFmpeg; the gapless-header correction changes no compressed audio packets.
Invalid non-finite input is rejected at the public boundary, matching SPEC's
audio policy, rather than relying on the old encoder's silent sanitization.

The synthetic H.264 fixture's valid baseline is normalized before adding an
empty NAL sample. Its fixed packet digest represents that independent baseline.
The production repair refuses files when FFmpeg also changes valid packet bytes;
the assertion is not relaxed to accept bitstream normalization.

## Execution evidence

The final `make test-device` run passes 1,254 package tests (57 MenuCatalog,
257 Formats and 940 Engine) and 13 app-hosted tests. It includes the Debug app
build. Capability-gated tests run on the real Mac with missing capabilities
treated as failures. Strict Swift format lint passes. Logs are local under
`build/v230-device-final.log` and `build/v230-lint-final.log`.

The release benchmark passes its menu, request parsing, image and video targets.
MP3 encodes the 10-second stereo fixture in 0.099 seconds, 100.5× real time on
Apple M5. This is not an M1 measurement. The M1 20× criterion remains unchanged
and is not claimed as verified on this machine.

Fresh independent editor, audio/output-safety and whole-diff reviews were
completed. Valid findings were corrected: numeric edits retained their draft
until commit, non-wheel zoom uses the pointer when present, natural playback
completion clears playback state, and original PCM extraction refuses timing
repairs. Review of those corrections found no remaining material issue.

The supplied TikTok URL was analyzed and downloaded through the native app.
Activity completion, Show in Finder, Quick Look playback and Undo were observed.
The saved file passes strict decoding with 590 video and 460 audio packets.
Host download UI checks cover English/Japanese, light/dark and narrow windows;
multiple-source selection and storyboard filtering also have automated proof.

On macOS 26.6.2 in an isolated VM, video left/right handles, one-drag Undo/Redo,
zoom buttons, Fit, click positioning and Save were exercised. The 0.250–1.708333
second range saves as 35 frames and 1.458333 seconds for both video and audio;
strict independent decoding succeeds and QuickTime plays through the end.

The VM audio panel also passed left/right handle drags, Undo/Redo, zoom buttons,
click positioning, setting the out point to the playhead, range playback and
Save. The saved 48 kHz stereo WAV contains exactly source frames 18,586 through
47,771 (29,186 frames), with every PCM sample matching the source slice. Both
disposable VM originals retain their SHA-256 digests. The isolated VM is stopped
and the host's original Dev app, profile and preferences are restored.

The audio panel's Fit button was compressed away in the 600-point Form. The
final adjustment moves Set In/Out onto the existing Undo/Redo row and retains
the zoom controls' intrinsic width. Its focused build, strict lint and separate
review pass. The post-adjustment rendered check was not completed: native input
control could not reach the final editor, and the browser tool rejected local
file-page access. No browser restriction was bypassed.

### Remaining verification limits

- The original reported music file is unavailable; its exact audible symptom
  has not been reproduced.
- Physical trackpad pinch, Command-wheel and editor zoom keyboard shortcuts
  were not confirmed with real input. Native canvas/model tests cover pointer
  anchoring, precision, eight-point snapping, Option release and skimmer state.
- Download windows were observed at 820- and 760-point widths, not the exact
  700 × 650 minimum. Multiple available resolutions and playlist intersections
  have automated proof, but a live multi-resolution picker was not additionally
  exercised in this final UI pass.
- English/Japanese and light/dark download screens were inspected on the host.
  The editor VM checks cover English/light; the full editor language/appearance
  cross-product and the final Fit adjustment remain visually unverified.
- Every operation family was inspected and exercised by the existing device
  suites; this is not exhaustive manual coverage of every setting combination.
- No release, tag, DMG build/publication, production-site update or release
  installation check was performed, as requested.
