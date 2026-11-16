# ADR 0067: Finder Preview panel

Date: 2026-11-17
Status: Accepted

## Context

The verified Quick Look extension spike could not override system previews for
media, HTML or plain text, and Finder consumed keyboard input. The docked host
panel spike established AX window tracking, Finder selection scripting and
CGWindow relative ordering. A host panel provides consistent preview ownership
and permits future keyboard input without changing Finder's built-in pane.

## Decision

Keep schema 3 and add optional localized previewTitle to menu.json and its
catalog hash, including recipe expansion. Place Finder Preview after the
optional update item and before operations for item and background menus.
Authenticate macease://preview?t=<token> like Update: exactly one current token
and an available host. This route neither starts a job nor writes history.

Own one FinderPreviewCoordinator in AppDelegate. Toggle by focused AX window
identity; follow newly focused Finder windows. Use AXObserver notifications,
coalesced updates and workspace visibility events. Convert AX coordinates using
the primary screen's top, match CGWindowID by Finder PID and bounds, and order
the normal-level panel directly above that window. Prefer right, then left,
then inset docking. Persist a 360-point default width clamped to 280 points and
half the usable screen width. Respect Reduce Motion for the opening slide.

Read Finder's window ID and URL selection with one compiled NSAppleScript on a
serial queue, at most one in flight. Poll visible/frontmost selection every
250 ms, read immediately on focus, and reject stale generations/window IDs.
Use a two-second Apple event timeout. Close removes observers/timers and cancels
inspection; pending Apple events cannot publish after closing.

Use a native sidebar material, compact header and footer, and a Quick Look fallback.
Show bounded folder counts and logical size, empty selection, multiple-file
navigation, Open and the existing media-editor path. Previews remain read-only.
Permission denial has explicit explanation,
System Settings links and Retry. Missing Accessibility uses a centered titled
panel; denied Automation retains docking. Log failures without selected paths.

Extend the Decision in this unpublished branch with UTType-selected text/code,
HTML, Markdown, JSON/plist, image, audio/video and PDF viewers. Reuse engine
encoding detection, safe Markdown conversion, JSON/plist formatting and audio
waveforms. Text reads are bounded to 4 MiB, with a labeled 256 KiB excerpt above
that size; syntax highlighting stops at 512 KiB. Explicit encoding choices
re-decode the original bytes. Binary plists expose formatted JSON only.

Share the engine's nonpersistent WebKit configuration. HTML scripts/network
reset off per selection; toggles recreate the web view. Install compiled rules
before loading; failure prevents loading. Offline rules deny all resource schemes
except file/data/blob, explicitly blocking HTTP(S) and WS(S). Network opt-in
permits those network resources but never external navigation. Limit file read
access to the selected parent directory; cancel other documents, schemes, hosts,
subframes, forms, popups and downloads. Markdown uses safe generated HTML with
no scripts, network or local resource base URL. Preserve engine conversion limits.

Use native text, image, player and PDF controls, small tool rows and adaptive
colors. Decode images frame-by-frame, load audio waveforms independently, and
remove player observers and content when selection generations change or the
panel hides/closes. Background reads/conversions reject cancelled results.

## Consequences

The unsandboxed host needs Accessibility and Finder Automation consent. The
sandboxed extension remains a menu and authenticated URL forwarder. Old schema-3
files remain readable. Geometry, menu compatibility and route regressions are
added without running xcodebuild or swift test. Full application compilation,
permission prompts, Quick Look interaction, display seams, full screen, Spaces
and Finder tabs still require native validation. QLPreviewView retains the
system's format support and fallback behavior. Folder inspection reports failure
when its bounds are exceeded instead of displaying incomplete totals.
