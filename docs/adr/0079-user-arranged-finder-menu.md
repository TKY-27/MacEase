# ADR 0079: User-arranged Finder menu and menu file schema 4

Date: 2026-11-24
Status: Accepted

## Context

ADR 0063 fixed the primary groups and their order, kept All Files operations in
More, and let users only pin or unpin groups with Show at Top Level in a
tri-state settings tree. Users could not reorder groups, place a group directly
in Finder's context menu, or hide a group without unchecking every leaf. Menu
values were scattered across the Finder Menu, Video and Audio pages. The schema
3 catalog hash joined fields with separator characters, so titles containing
those characters could imitate a field boundary, and a click on an old menu
used whatever menu file was current. This supersedes the placement, Show at Top
Level, All Files and schema parts of ADR 0063, and the `previewTitle` and
`updateTitle` fields of ADRs 0065 and 0067; earlier ADRs stay unchanged as
history.

## Decision

Give every scope (Commands and each kind) the ordered sections MacEase Menu,
More and Hidden; Commands also has Finder Menu. Store only customized scopes,
by group ID, as versioned JSON in UserDefaults; uncustomized scopes follow the
catalog defaults, and new groups join More. Migrate the legacy placements and
fully hidden groups once on first launch, reproducing the previous menu, then
delete the legacy key. Keep a shown group non-empty: losing its last leaf moves
it to Hidden. Keep cluster separators only while a section has its default
order. Replace the settings tree with one organizer list per scope, using one
flat list whose header and placeholder rows are movable but not selectable, and
move editable values into Options… sheets.

Publish menu.json schema 4: entries in display order with a required placement,
an ordered `commands` list with optional leaves instead of the update and
preview titles, and a catalog version computed over a length-prefixed encoding
of every field. Make the extension reject a file whose version does not match
its content and give each menu build its own tag range bound to that build's
file.

## Consequences

Users decide what appears in Finder's menu, where, and in what order, including
All Files groups and host commands. A new extension shows only Open MacEase
until the host rewrites a schema-3 file, which it does at launch; every catalog
version changes once with this update. Downgrading after migration loses the
arrangement, because the legacy placement key is gone. Header rows can be
dragged, which the model ignores, and VoiceOver reads them as headers;
VoiceOver operation itself is unverified.

Alternatives rejected after a spike on macOS 27: immovable header and
placeholder rows, which made SwiftUI refuse drops into empty sections and into
the first slot of a section; one `Section` per menu section, whose same-list
drags reach only that section's `onMove`.
