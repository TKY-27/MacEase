# ADR 0066: Download and editor feedback

Date: 2026-11-17
Status: Accepted

## Context

Return in the download URL field always reanalyzed, discarding listed results.
Download closed the window, so progress and failures appeared only in Activity,
and the destination could not change. Audio Only had no quality choice and
format labels did not say which choices re-encode. The editor closed before its
save finished, hid Reset All in a one-item More menu, mixed export settings
with segment controls, offered three controls for speed and mixed seconds with
timecode.

## Decision

Return downloads while analysis results are listed; any URL edit already clears
them, so Return analyzes again. Choose… replaces the destination for one
window; MediaDownloader.makeBatch still validates it. After Download the window
stays open, clears the URLs and tracks rows by batch ID and item index.
JobCenter.runDownloads returns that batch ID and ActiveBatch exposes per-item
stage fractions and item outcomes from the engine's progress snapshots, so rows
reuse Activity progress and UserMessages wording. Finished rows immediately
show outputs, failure reasons or cancellation while other items continue.
Retry resubmits only one failed, non-cancelled row. Closing never cancels jobs.

Add an optional MediaDownloadSelection.audioBitrate (128, 192, 256 or 320 kbps)
accepted only for M4A and MP3 and applied only when converting. Group formats
under No Re-encoding and Converts If Needed, and explain unshared resolutions.

The editor's model plans the save, records the batch ID, awaits the JobCenter
task and reports the first failed or skipped item. Success closes the window;
failure keeps it open and retryable. Partial photo success removes saved photos
from the session and its edit history, retaining unsaved edits for retry even
after cancellation. Saving pauses active playback. The keyboard monitor and model
mutations are disabled while saving, including keyboard playback and transport.
Undo becomes a split control holding Reset
All Edits. Export resolution moves to a pinned section, Add Videos… to the
timeline bar, speed to presets plus one field, and boundaries to m:ss.sss.

## Consequences

Users see download and save outcomes where they started them. Activity still
appears and offers its own batch retry, which can duplicate a row already
retried in the window; commits never overwrite, so duplicates are numbered.
A partially failed multi-photo save stays open and retrying saves only the
unsaved photos. App-hosted tests cover Return routing, per-item outcomes and
retry before batch completion, editor save transitions, partial replacement and
cancellation, and save-time keyboard and mutation guards; a package test covers bitrate validation
and MP3 arguments.
