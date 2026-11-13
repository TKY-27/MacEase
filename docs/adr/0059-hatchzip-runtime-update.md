# ADR 0059: HatchZip runtime update

Date: 2026-11-14
Status: Accepted

## Context

The owner requested current dependency updates before the v3 release.
HatchZip 0.1.10 is newer than the prepared 0.1.9 integration.

## Decision

Pin HatchZip 0.1.10 at `e56b4ceca0d28e967ce04834895e693c84a2a7a0`
with its source checksum in `Vendor/deps.lock`. Retain the isolated helper,
checkpoint and quarantine patch, existing archive formats and disabled RAR.
Verify the resolved dependency licenses and regenerate notices.

Keep yt-dlp 2026.10.26, gallery-dl 1.32.19 and yt-dlp-ejs 0.8.0 after
checking their current stable releases. RustXNG is not a MacEase dependency;
do not introduce a metasearch service into this maintenance update.

## Consequences

`docs/dependency-update-v3.md` records upstream evidence and actual checks.
The helper's folder metadata restoration and completion warnings need host
integration verification alongside existing cancellation and recovery behavior.
The source pin and public runtime notices remain reproducible.
