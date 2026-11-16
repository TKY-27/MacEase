# ADR 0063: Finder menu primary groups and More

Date: 2026-11-17
Status: Accepted

## Context

A single video exposes too many operation groups directly in Finder. Shared
Rotate and Convert groups need stable identities for placement settings, while
selection pruning must preserve the request indices published by the host.
Legacy video trimming duplicates the editor. Base64 copying, source inspection
and natural-language AI plans add actions outside the retained feature set.
This supersedes the corresponding parts of ADRs 0010 and 0057; earlier ADRs
and validation records stay unchanged as history.

## Decision

Use the fixed primary groups in SPEC sections 4.2 and 4.4. Put remaining groups
and all All Files operations in one final More submenu. Never adapt positions
to usage or fill pruned primary slots. Mixed selections keep kind submenus for
primaries and prefix More operation titles with kind and count, limiting menu
depth to four levels. Folder-background yt-dlp remains outside MacEase.

Keep schema 3 with optional groupID, placement and localized moreTitle fields,
all included in the catalog hash. Missing placement uses the default table.
Preserve each entry's original index. Persist placement by stable visible-group
ID, independently of visibility, with native Show at Top Level controls in the
existing settings tree. All Files operations always remain in More. Reset All
clears overrides; Document and Plist kinds join the settings tree.

Delete legacy video Trim, Copy as Base64, Inspect Source and Ask Apple
Intelligence, including exclusive panels, planners, strings and tests. Route
compression retries through the video editor. Decode historical video.trim
batches as video.edit while preserving commit records and Undo. Remove stale
visibility keys after migrating hidden video.trim intent to video.edit once.
Keep VideoEdits trimming internals, download source recording, AI rename,
organization, OCR and subtitles.

## Consequences

Finder menus stay predictable and shorter. Less common operations require
opening More, and users can change group placement without enabling hidden
leaves. Old schema-3 files retain default placement. Historical trim batches
remain undoable. Package and app-hosted regressions cover placement, pruning,
indices, persistence and compatibility; build, runtime timing and native UI
validation remain required on the parent host.
