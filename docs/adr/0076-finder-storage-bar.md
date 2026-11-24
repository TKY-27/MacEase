# ADR 0076: Finder storage bar over Finder's status bar

Date: 2026-11-24
Status: Accepted

## Context

The owner asked for volume capacity and selection details at the bottom of
Finder windows. Finder offers no extension point there. No live Finder window
could be measured; on macOS 27, Finder's StatusBar.nib declares a 20-point view
with a one-point top separator, 11-point text and a 133-point icon-size slider
in icon view. Measuring the size of selected items would read inside
privacy-protected folders and removable or network volumes on every selection
change, and macOS would show file-access prompts merely because the user
selected something. The first implementation also inspected selected files
through Finder Preview's code path while the preview was off.

## Decision

Draw a display-only, click-through, transient panel over Finder's status bar,
only while Finder's `ShowStatusBar` preference is on (read with CFPreferences,
never written). Keep the bar height, bottom inset and icon-slider width and
margin together as one calibration type. Reuse Finder Preview's window tracker
and selection poll; the Finder script also returns the front window's folder and
view mode, each inside `try`. Leave the icon-size slider uncovered in icon view
and whenever the view mode is unknown. Show the selection count only. Never
open, stat or identify selected items, and never inspect files when Finder
Preview is off. Read the startup disk's capacity from its resource values and
every other volume's from the kernel mount table with `MNT_NOWAIT`, naming it by
its mount point. Keep strip-only polling silent: never request Automation
consent, stop retrying after a denial, log it once, never put Finder Preview into
its denied state and never drop a consent request the user starts. Turn it on by
default, independently of Finder Preview.

## Consequences

The strip causes no file-access prompts and cannot hang on an unresponsive
mount. Selected-items size is not available until a prompt-free mechanism
exists. Non-startup volumes show the mount point's name and the mount table's
available blocks rather than purgeable important-usage space. If the assumed
nib metrics are wrong, a sliver of Finder's bar shows, the strip covers a few
points of the file list without blocking clicks, or the gap beside the slider
needs tuning. Live calibration is required before release. Users without
Accessibility see nothing and are never prompted for it by the strip.

Alternatives rejected: showing the selected items' total size, with or without
a size bound or a "Calculating…" state; reading non-startup capacity through
`resourceValues` or `displayName(atPath:)` on the volume, which can prompt;
covering the whole status bar in icon view, which hid Finder's slider.
Writing Finder's preferences or relaunching Finder to show the status bar is
excluded.
