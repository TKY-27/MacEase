# 13. Flect-style menu-first direction

Date: 2026-10-21
Status: Accepted

## Context

The owner changed the target v1 direction on 2026-10-21. MacEase adopts
Flect's menu-first interaction and the scheduled functional parity work,
while retaining native macOS behavior, mixed selections, safe commits,
and durable Undo. The owner selected new-file output as the default, with
safe replacement available in Settings.

Flect is Apache-2.0. Its developer has given permission to study and reuse
it. That permission does not replace the license's redistribution terms.
Flect's implementation targets Windows with C#/.NET, WPF/WinUI, shell COM,
FFmpeg command-line tools, and Python transcription. MacEase targets native
macOS frameworks and a Swift engine with approved permissive dependencies.

ADR 0004 prohibited even reading GPL-family sources. The source policy now
permits study while continuing to prohibit incorporation of copyleft code.
This decision supersedes that reading ban and ADR 0005's default-replacement
policy. ADR 0007's replacement sequence and ADR 0011's commit and Undo
safeguards remain in force.

## Decision

- Use Flect-style menu-first UX. Preset and format leaves run immediately.
  Custom Size is limited to Resize and Compress. Flip shares Rotate,
  animations share Convert, and JSON commands are flat leaves. Schema 2
  records preset-group separators, editable values, and selection constraints.
- Preserve Kind (n) submenus for mixed selections. Prune by extensions and
  per-kind counts, with host content validation. Do not read selection contents
  or sizes in Finder Sync without an accepted platform spike.
- Add one shared Activity window, on by default, after 0.8 seconds, without
  stealing Finder focus. Auto-close clean successes, retain visible problems,
  and avoid duplicate notification feedback. Keep menu-bar history and Undo.
- Use sidebar Settings with a Finder Menu page and per-preset visibility.
  Apply default-hidden presets only to new installs. Move persistent parameters
  out of removed option panels. Use one Welcome window and consistent normal
  launch, reopen, and open-URL routing.
- Default converting and editing to Save as new file. Use Flect-style sibling
  naming and collision suffixes with coordinated no-overwrite commits. Record
  created files in history so Undo removes them without changing the source.
  Replace original remains an explicit Settings choice and keeps SPEC 3.5's
  verified-output, staging, Trash, and coordinated replacement sequence.
  Exports, extracts, and reports always derive. SPEC 3.5 defines the boundaries.
- Implement independently in Swift. ImageIO, Core Image, AVFoundation,
  VideoToolbox, Vision, and Speech fit macOS better than translated Windows
  orchestration. Independent implementation gives control over quality,
  metadata, streams, cancellation, and maintenance in the existing engine.
  Reuse only facts and data such as extension lists, menu taxonomy, and preset
  values. No Flect code, artwork, or other assets are copied.
- If Flect code is ever copied, comply with the
  [Apache-2.0 redistribution terms](https://www.apache.org/licenses/LICENSE-2.0).
  Include the license, retain applicable attribution, identify modifications,
  and carry required NOTICE content. Record Apache-2.0 NOTICE and attribution
  in `THIRD_PARTY_NOTICES.txt` before distribution. Informal developer permission
  does not waive those terms. The current independent implementation creates
  no Flect code or asset attribution requirement.
- Permit reading GPL, LGPL, and AGPL projects, including FFmpeg, LAME,
  gifski, pngquant, libimagequant, and Clop, to study architecture and algorithms.
  Never copy, translate, adapt, or incorporate their code. Implement independently.
  Bundled dependencies remain permissive, pinned, and recorded in SPEC 3.7.
- Include explicit image and video HDR-to-SDR conversion with real tone mapping,
  content detection, color management, preservation checks, and device quality
  acceptance. SDR-to-HDR conversion is out of scope (owner decision).
- Prefer proven libraries, frameworks and components to custom code when
  they give a better result in quality, reliability or maintenance. Verify
  each license before use: permissive licenses (MIT, BSD, Apache-2.0, zlib,
  ISC and similar) with their notices recorded in THIRD_PARTY_NOTICES and
  SPEC 3.7; GPL-family code is never incorporated.

## Consequences

- SPEC describes the finished target, including work that follows this decision.
  Documentation changes alone do not establish implemented or tested behavior.
- More work runs directly from Finder. Settings becomes the persistent home
  for quality, animation, background, subtitle, audio, PDF, and menu values.
- New-file output uses more disk space and can add sibling files. Sources stay
  intact and created outputs remain undoable. Users can explicitly choose
  replacement to retain the earlier behavior.
- Existing visibility choices and preset units survive migration. Output mode
  defaults to new file unless an explicit saved choice exists.
- Scheduled parity includes audio transcription, broader text recognition,
  richer reports and JSON sorting, duplicate filters, exclusions, OCR encodings,
  embedded-raster SVG, loose PDF pages, and editable menu values. WMA, AV1
  video encoding, AVI MPEG-4/MP3 encoding, and alternative transcription
  backends remain evaluated and deferred.
- Neither mode permits silent frame, stream, metadata, alpha, or channel loss.
  Target-size failures remain failures. Duplicate deletion retains byte proof
  and at least one copy. Reports never overwrite existing files. Durable Undo
  and original-file protection remain release requirements.
- HDR work needs real capture fixtures, test patterns, and HDR/SDR display
  checks. Unqualified SDR expansion stays absent from shipped menus.
