# 7. Same-name replace clones the original into staging

Date: 2026-10-20
Status: Accepted

## Context

SPEC.md section 3.5 originally cloned the original to a sibling with a hidden
temporary name, moved that clone to the Trash, and then swapped the output in
with `replaceItemAt`. The Trash keeps the name an item had when it was trashed,
so the original would sit in the Trash under a hidden dot name. Finder hides
dot files, so a user looking for the original in the Trash would not see it,
and Undo needs Full Disk Access to read the Trash on some systems. The hidden
sibling also appeared briefly in the user's folder, where cloud sync clients can
pick it up.

## Decision

The clone is written into the item's staging directory (on the same volume,
from `.itemReplacementDirectory`) under the original's own name, moved to the
Trash from there, and then `replaceItemAt` swaps the output in. Everything else
in the replace sequence is unchanged.

## Consequences

- The trashed original is visible in the Trash under its own name.
- Nothing temporary ever appears in the user's folder.
- Finder's Put Back points at the removed staging directory, so it cannot
  restore the file; MacEase's Undo, or dragging the file out of the Trash, does.
- A crash between steps still leaves the original in place, never neither.
