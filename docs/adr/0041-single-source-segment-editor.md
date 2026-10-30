# 41. Single-source segment editing and prepared previews

Date: 2026-10-30
Status: Accepted

## Context

The owner wants familiar basic video editing with immediate playback and a
simpler inspector. A single start/end range cannot represent deletion from the
middle, reordering or per-segment adjustments. Conditional player-view creation
and repeated precise seeks can delay playback presentation.

## Decision

Represent a video edit as ordered source segments with stable identities,
source bounds, speed, volume and color/style settings. Splitting inherits
settings; deleting closes the gap; duplication creates a new identity.
Reordering and duplication may revisit source ranges. Geometry and resolution
remain global. Keep legacy single-range decoding and original-source exports.

Provide split, delete, duplicate and movement through visible controls and a
timeline context menu, with Command-B, Backspace and drag reordering. Editing
keys belong to focused text controls. Every action or drag has one Undo step.
The owner limits this release to editing one source video; additional source
import, multiple tracks and transitions are outside the requested scope.

Share source/output timing between preview and export, with continuous video
and audio encoding and exact cuts. Keep the player surface mounted, prepare
frames before display and avoid redundant seeks. Coalesce preview work and
use bounded interactive photo previews followed by refined rendering.

Remove histogram UI and processing, keyframe-mode controls and slider tick
rows. Order media menus Edit, Convert, Compress, Resolution, followed by
related operations. Keep native Photos/iMovie interaction conventions.

## Consequences

Compatibility, actual output frame order, per-segment speed/audio/color,
continuous timing, keyboard focus and Undo require regression coverage.
Physical-machine rendering and responsiveness checks remain required. The
owner authorizes v1.4.0 publication after checks and multiple fresh-context
GPT-6.1 Sol reviews focused on practical correctness and stability.
