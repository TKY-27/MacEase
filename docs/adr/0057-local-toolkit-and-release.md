# ADR 0057: Local toolkit and v3.0 release

Date: 2026-11-05

## Status

Accepted; implementation and release verification are tracked separately.

## Context

The owner requested gallery downloads, Android-friendly file sharing, local
media enhancement, related-file discovery and file encryption, followed by a
v3.0.0 release. The earlier no-release instruction is superseded.

## Decision

Keep original-file protection and the existing commit pipeline. Group web
downloads in one window. Run gallery-dl through its public command-line
interface as a separately licensed program; distribute the exact source and
license without incorporating its GPL implementation into the MIT app.

Use temporary token-authorized local sharing with explicit lifetime controls.
Keep enhancement and similarity analysis on-device. Pin gallery-dl 1.32.19 in
`Vendor/media-tools.lock`; support direct posts/albums only, nonrecursive
`--dump-json` analysis and at most 512 images. Retain `MacEase Source.json` for
galleries and WhereFroms source URLs for video/audio. Inspect Source is hidden
by default, opt-in through Finder Menu settings, and shows recorded links and
SHA-256 without claiming authorship or authenticity.

Sharing uses explicit Start, a selected private LAN interface, a random 32-byte
token, at most 20 regular files and a 15-minute lifetime. Stop or window close
invalidates access. Disclose unencrypted HTTP and that link holders can download.

Ship Swin2SR classical SR ×2 as a compiled Core ML model with Apache-2.0 model
card/license and the revision/hash pins in `Vendor/upscaler.lock`. Its pinned
build-only Python environment converts the model; no Python/PyTorch/Transformers
ships for image inference. Limit input to one opaque 8-bit SDR still up to
1 MP; reject HDR, alpha, animation and multipage input. Always derive a PNG.
The observed M5 1 MP run took 134.42 seconds and 1.33 GB RSS; this is not a speed
or quality guarantee.

Ship MIT GTCRN and Spleeter 2stems models with sherpa-onnx 2.0.1 (Apache-2.0)
and ONNX Runtime 1.28.2 (MIT). `Vendor/ai-audio.lock` and `docs/ai-audio.md` own
exact provenance, the independent Spleeter checkpoint comparison and its
metadata-only 44,100 Hz correction. Preserve runtime notices and Eigen MPL-2.0
corresponding source. Run CPU inference in bounded chunks: speech up to ten
minutes to 16 kHz mono WAV, separation up to five minutes to both vocals and
instrumental as 44.1 kHz stereo WAV. Retain originals and disclose tag loss,
stereo speech downmixing and 16-bit native intermediates.

Related-file search is read-only within the chosen folder, defaulting to the
source folder. Exact matches require size, SHA-256 and byte comparison; local
Vision distance at most 0.5 indicates similarity, not duplication.

Use the official BSD-3-Clause age v1.3.2 library in an isolated executable with
standard age scrypt ciphertext. Send session-only passphrases solely through
standard input; new passwords require twelve characters and confirmation.
Authenticate before plaintext publication, verify ciphertext by decrypting and
comparing hash/size, preserve sources and avoid occupied names. Authenticated empty plaintext is supported and validated before publication.

Initially update HatchZip core to v0.1.9 at
`bc0610b1279f2601c4008317414cc5ba44a1ff38` for dot-path, hard-link and output
verification fixes; ADR 0059 advances this pin to 0.1.10. Preserve the existing format scope, excluding HatchZip RAR
and tar.xz, and its durable destructive-extraction contract.
Do not create an autonomous web research agent or claim inferred provenance
as evidence; expose recorded source information within the download workflow.

## Consequences

The application remains account-free. Explicit temporary private-LAN sharing
extends the earlier network policy. Enhancement resources ship with the app;
there is no runtime model download or future model-installation UI in this
implementation. `make toolkit` builds the age bridge and audio/image resources;
bootstrap also installs missing Go and Python 3.11. Third-party runtime/model updates
ship with reviewed app releases. Package size, licenses, measured behavior and
verification limits must be documented before publication.

Implementation is not release acceptance. Full current validation, actual GUI
interaction, final signed-DMG resources/install checks and public release proof
remain with the parent integration task. Retain the future VoiceOver scope
exclusion in ADR 0048; do not fabricate a VoiceOver or other acceptance pass.
