# ADR 0080: Finder commands and cross-volume moves

Date: 2026-11-24
Status: Accepted

## Context

Finder lacks or hides several everyday conveniences: creating a new file in a
folder, cutting and moving items, copying paths and opening a terminal in a
folder. The Finder extension is sandboxed and may only read
`sender.tag` and the selection before opening a URL; it cannot write files.
Finder Sync's general-pasteboard writes from the extension were not verified.
Moving items is a write to the user's originals, and a move to another volume
is a copy followed by a removal unless the design says otherwise. The first
cross-volume design removed the original after copying, with rollback,
detached finalization and paired history records; a review showed that partial
cleanup could destroy items in both locations. New files and grouped outputs
also failed on exFAT, which does not support `RENAME_EXCL`.

## Decision

Add host commands New File, Cut, Move Here, Copy Path and Open Terminal Here to
the Commands scope, in MacEase Menu by default. The extension sends
authenticated, version-bound requests; the host validates paths, the current
catalog version and the published action again, and does the work. Cut records
item stamps off the main actor and writes file URLs to the host's general
pasteboard; the host watches only the pasteboard's change count while a cut
exists. Copy Path writes POSIX or shell-quoted text. Open Terminal Here uses
`NSWorkspace` with the configured application and sends no Apple events. New
File runs through the engine with ordinary history and Undo.

A move on one volume is one exclusive rename with an ordinary Rename record. A
move to another volume makes a verified copy and always keeps the original; it
records one Derived entry and a warning that names both paths, and Undo removes
only an unchanged copy. Publish through one exclusive step that falls back to an
exclusive reservation and rename when `RENAME_EXCL` is unsupported. Let new
empty Text and Markdown files bypass the non-empty output rule through a
separate check, while RTF and DOCX must open as documents.

## Consequences

Cut and Move Here behave like Finder on one volume. Across volumes the user
ends with two copies and removes the original themselves; MacEase never trashes
or deletes it. Moves, new files and grouped outputs work on exFAT and FAT32,
with the residual race between reservation and rename recorded in
`docs/spikes.md`. Real Finder interaction, File Provider hydration, SMB and NFS,
and terminal applications other than Terminal were not exercised.

Alternatives rejected: copying and then moving the original to the Trash or
deleting it, for the data-loss risk above; writing the pasteboard from the
Finder extension, because a sandboxed test app could write a named pasteboard
but the real extension's general-pasteboard writes could not be verified
without driving Finder; AppleScript for Terminal, which needs Automation
consent.
