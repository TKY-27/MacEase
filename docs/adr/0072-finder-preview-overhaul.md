# ADR 0072: Setting-driven, content-only Finder Preview

Date: 2026-11-24
Status: Accepted

## Context

ADR 0067 toggled the panel by its presence, so closing a Finder window or
quitting Finder turned the preview off, and launch asked for permissions before
the user had chosen the feature. Its layout spent most of a narrow panel on a
header title, name, kind and size, Information rows, an action bar, folder
totals and aspect-capped previews, and it waited for metadata before showing
content. Text editing inside the preview needed its own Replace commit,
dirty-buffer pinning and quit protection, a write path that a viewer does not
need. Several common types (SVG, fonts, many media containers) fell back to
Quick Look, and a file whose name did not match its content reached a viewer
that could not show it. This supersedes the corresponding parts of ADR 0067
(presence by panel, layout, Escape closing, text editing and its `text.edit`
batch) and of ADR 0068 (consent at the first selection request); earlier ADRs
stay unchanged as history.

## Decision

Drive presence from one saved setting, off by default. While it is on, dock
beside the front Finder window whenever one is visible, hide when there is none
or Finder quits, and return automatically. The close button, Command-W, the
notice window, the Finder command, the menu-bar item and the URL route all flip
the setting; Escape does not close the panel. Ask for Accessibility only when
the user turns the preview on and for Finder Automation only after a user
action. Make the panel join the active Space and full-screen spaces and become
key only when a control needs keyboard input.

Show only content under one 52-point bar holding the viewer's controls, the
selection stepper and the close button. Wait only for the file kind. Identify
the first bytes before choosing a viewer: refuse empty files and binary content
under text names, and mark other name mismatches. Add native viewers for SVG
(drawn as an image), fonts (Core Text, bounded before loading), encodings
beyond the engine's (UTF-32, GB18030, Big5, EUC-KR), PDF navigation, Live Text,
image information and audio artwork; add Convert and Play for media
AVFoundation cannot play, bounded by duration and size and never saved. Share
one Find bar. Keep the previous preview visible while the next file loads, dimmed
after 200 ms. Add Settings > Finder Windows for per-type switches, code font,
wrapping, font sample text and trusted folders. Make every viewer read-only and
remove text editing, its engine operation and its Replace path, while old
`text.edit` history records stay decodable and undoable.

## Consequences

The preview behaves like a persistent pane: it survives window changes and
relaunches, and nothing prompts at launch. Content gets the whole panel, but
file name, kind, size and folder totals are no longer shown; Finder's own pane
or Get Info provides them. Users who edited text in the preview must open the
file in an editor. Multi-track media and formats AVFoundation cannot play need a
conversion step. Real-host validation of Spaces, full screen, tabs and live
docking is still required.

Alternatives not taken: a Quick Look extension, which the recorded spikes rule
out; FFmpeg for Convert and Play, which the engine's own playback conversion
makes unnecessary; a Monaco-style web editor for code; and AX selection
notifications instead of the 250 ms selection poll, deferred until a trusted
build can test them on a real Mac. The removed media speed, frame step, A–B loop,
waveform and PDF thumbnail controls duplicated the native players.
