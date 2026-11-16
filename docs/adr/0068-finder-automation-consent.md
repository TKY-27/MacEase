# ADR 0068: Finder Automation consent before selection reads

Date: 2026-11-17
Status: Accepted

## Context

The signed v3.1.0 candidate on macOS 26.6.2 displayed a timeout during the
initial Finder Automation prompt. Background selection retries presented the
prompt again while the user was deciding.

## Decision

Use `AEDeterminePermissionToAutomateTarget` on the serial selection worker
before compiling the Finder script. Keep at most one request in flight while
the system waits for the user. Apply the existing two-second timeout to
selection reads after authorization. Recheck the active panel and generation
before reading after consent. A permission denial makes an explicit retry
check authorization again.

## Consequences

The main thread remains responsive while the system prompt is open. Closing
the preview invalidates the result even if the system prompt is still active.
Denied permission retains the existing settings link and retry behavior.
