# 5. Replace in place with Trash and undo

Date: 2026-10-20
Status: Accepted

## Context

The product goal is to transform the selected file itself rather than create a
copy next to it, while never losing user data.

## Decision

- Transform operations replace the original. The original is moved to the Trash
  only after the output is fully written to a staging directory outside the
  user's folder and verified by decoding it.
- When the extension changes, the output is placed under its new name before the
  original is trashed; when the name is unchanged, a clone of the original is
  trashed and `replaceItemAt` swaps the file.
- Operations that produce something different in nature (GIF from video, audio
  extraction, subtitles, archives, exports, background-removed video, RAW
  conversion) create derived files and keep the original.
- Every batch is recorded in history and can be undone.

## Consequences

- A crash can leave both files but never neither.
- Volumes without a Trash fall back to derived output.
- Undo depends on Trash contents; items emptied from the Trash or edited after
  commit are skipped with a reason.
