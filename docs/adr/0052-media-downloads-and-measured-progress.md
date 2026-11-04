# 52. Media downloads and measured progress

Date: 2026-11-05
Status: Accepted

## Context

The owner requested Finder-based yt-dlp downloads, accurate progress after two
seconds, official-site update navigation and a public v2.2 release. MacEase
source must retain MIT. The owner accepts separately licensed FFmpeg programs
and deferred Intel support after reviewing its validation and maintenance cost.

## Decision

Implement SPEC section 22. Bundle source-distributed yt-dlp and private runtimes;
permit download-only LGPL FFmpeg/ffprobe and their required dependencies as
independent executables with notices and corresponding source. Do not link their
code into MacEase or replace existing local transformation engines. Pin all
runtime inputs. Disable tool self-updates and user configuration/plugins.

Expose yt-dlp directly for a folder/background. Analyze public URLs before
selecting playlist entries, formats and optional subtitle sidecars. Stage and
verify outputs before existing no-overwrite commits and Undo. Retry only failures.

Supersede ADR 0051 with automatic Activity after two seconds, enabled once on
upgrade and on reset. Subsequent user preferences remain authoritative. Display
measured stage progress or an indeterminate bar, never time-driven percentages.
Retain GitHub update detection and open the localized official download page.

## Consequences

The bundle grows and requires independent executable signing and source delivery.
Public site compatibility changes over time. Cookie access, DRM bypass, live
recording, Intel and older macOS remain outside this release. No existing local
operation depends on the new download tools. Release acceptance includes native
UI, file safety, fixed streaming fixtures and public-source smoke checks.
