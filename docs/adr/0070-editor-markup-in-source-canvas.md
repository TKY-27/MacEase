# ADR 0070: Editor markup in source-canvas coordinates

Date: 2026-11-24
Status: Accepted

## Context

The photo and video editor needed redaction (mosaic, blur, solid) and
annotation (box, arrow, text). A redaction must keep covering the sensitive
content when the user later crops, rotates, flips, straightens or resizes, and
video redactions must stay on the same source frames when segments are split,
reordered, duplicated or retimed. Preview and export already share their
geometry and colour functions; a second rendering path would let them disagree.
The first engine review found redaction rectangles rounding inward, preview and
export selecting overlays at different times, frame fetches ignoring overlays,
and line and text floors defined per render resolution.

## Decision

Store every markup item in the oriented source canvas, before crop, rotation and
flips, in normalized top-left coordinates. A rectangle drawn on a straightened
image stores its bounding box, so it covers at least the dragged area. Video
items carry a source index and a source-time range; one function maps the
displayed source frame to the active items for preview, export and frame
fetches, using each source's own frame rate.

Render redactions into the source pixels before geometry, automatic correction,
style and adjustments, with extents rounded outward. Mosaic averages each block
before pixellating; a region narrower than a block uses its own average. Draw
box, arrow and text after geometry and colour on the output, mapped through the
same rounded crop bounds as the image, upright and never mirrored, with sizes
and floors defined against the full-resolution output and scaled for preview.
Key the annotation cache by content, not only identity. Limit an edit to 50
items and text to one line of 200 characters. Treat any markup as a colour
edit, so HDR sources save a new SDR file and gain maps cannot keep unredacted
pixels.

## Consequences

Redactions survive later geometry edits and timeline changes without migration.
Annotations stay legible and upright regardless of the final orientation, and
styles never tint them. Markup on HDR media always produces a new SDR file.
Fifty photo annotations measured a median of 37.7 ms per preview frame on a
12-megapixel HEIC (`docs/spikes.md`); the editor does not promise 60 fps at that
count.

Alternatives rejected: storing items in output coordinates, which a later crop
or rotation would detach from the covered content; drawing annotations before
geometry, which would rotate and mirror text; selecting video overlays at the
export frame's centre time, which left a boundary frame unredacted in export
while the preview showed it covered; sampling one pixel per mosaic block, which
made thin dark text vanish instead of turning grey.
