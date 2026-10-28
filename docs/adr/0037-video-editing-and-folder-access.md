# 37. Video editing and folder access

Date: 2026-10-28
Status: Accepted

## Context

Users need intentional low resolution independently of target-size compression,
custom playback speeds, and combined edits. Finder Sync is enabled but omitted
from this Mac's iCloud-managed Desktop and Documents context menus. Registering
folders and granting filesystem access are different operations.

## Decision

Add low-resolution presets, a typed video edit request, and 0.5–4× playback
speed with arbitrary fractional input. Reuse video sampling, PCM decoding,
metadata checks and the staged commit pipeline. AVAudioUnitTimePitch renders
offline from a staged PCM file, keeping memory bounded and audio pitch intact.
Use one source/output timeline and verify pitch and synchronization separately.

Explicitly register standard and bookmark-resolved user folders alongside roots.
The host owns bookmarks; the extension receives optional resolved menu-file
paths and rereads after notifications. Settings and Welcome use NSOpenPanel.
Report registration and observed directory access separately.

Provide a native Services operation chooser for iCloud locations that suppress
Finder Sync. It uses the same catalog, selection filtering and host dispatch.
The user approved this fallback after the behavior was reproduced.

## Consequences

Legacy video.trim remains readable and callable. Its hidden-menu preference
migrates to video.edit. Missing folder fields remain compatible with old menus.
No new dependency or broader permission grant is introduced. Unsupported
properties still fail or warn through the existing output-mode policy.

Release 1.2.0 requires local build, tests, lint, device checks, and at least two
fresh GPT-6.1 Sol/high reviews. Valid High/Critical findings block publication.
Publish the signed DMG and checksum locally without reenabling disabled CI.
