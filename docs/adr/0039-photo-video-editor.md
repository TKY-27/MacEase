# 39. Shared photo and video editor

Date: 2026-10-30
Status: Accepted

## Context

The owner requests a Mac editing workspace inspired by direct manipulation in
Photos, with photo color editing and a replacement for the earlier video panel.
Preview and export must agree while retaining original-file protections.

## Decision

Use a resizable 1280×720 workspace with native controls, a large preview, a
right inspector and a bottom video timeline. Share normalized display-space
geometry and Core Image adjustments through typed ImageEdit and VideoEdit
values. Preserve older VideoEdit decoding with neutral defaults. Keep session
Undo in memory, cache photo automatic correction, and serialize cancellable
preview work with generation checks. Native videos use AVPlayer; supported
non-native formats use disposable playback copies and export from the source.

HDR color edits produce SDR in a new file even when Replace is configured.
Show this before Save and use SDR for the preview. Geometry-only editing
retains existing HDR preservation/refusal rules. Reject animated and multipage
photo inputs, derive RAW outputs, and recheck source identity before committing.
No native dependency is added.

Version 1.3.0 is build 4. Complete three fresh GPT-6.1 Sol/high reviews and
physical-Mac verification before pushing main and publishing the locally signed
DMG. GitHub Actions stays disabled. The owner explicitly excludes actual
VoiceOver operation and macOS 26 VM visual interaction from this release gate;
both remain unverified. All other acceptance requirements remain in force.

## Consequences

Editing shares existing output validation, collision handling, Trash and Undo.
The editor does not persist projects or offer multitrack, generative repair,
curves, custom saved styles or batch edits. New files preserve originals when
HDR color fidelity cannot remain HDR. Platform compatibility is macOS 26+, and
actual validation on the available macOS 27 Mac does not establish the two
excluded accessibility/platform interaction checks.
