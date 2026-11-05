# 54. Familiar editor layouts and HE-AAC decoding

Date: 2026-11-05
Status: Accepted

## Context

The owner reported that the photo/video editor, audio trim and download windows
were hard to operate and looked like dated form layouts, and asked for layouts
matching common editing software. MP3, WAV and other encoded extraction still
sounded wrong while M4A copies did not. A TikTok download and the owner's
extracted files reproduce it: the HE-AAC track description reports its 22,050 Hz
core rate, while AVAssetReader decodes 44,100 Hz. Encoders were configured for
the core rate, and timestamp continuity dropped about half of the samples.

## Decision

Describe AVFoundation audio tracks with
`CMAudioFormatDescriptionGetRichestDecodableFormat`, and fail any decoded buffer
whose rate or channel count differs. Packet copies keep their original format
descriptions. A regression fixture muxes an HE-AAC track into the existing H.264
clip.

Editor windows use the dark appearance, a bridged unified toolbar, a viewer with a
centred transport and a sectioned inspector. Audio trimming moves from a floating
form to a resizable dark window with a full-width waveform, centred transport and
typed timecodes. The download window becomes a URL field, a selectable result list,
grouped Video/Audio options and a destination footer. Return analyzes new URLs;
once results are listed, Return downloads the selection. Model behaviour, Undo, editor shortcuts,
snapping and file safety are unchanged.

## Consequences

HE-AAC and HE-AAC v2 videos extract, convert, edit and transcribe at their real
rate. Unknown future layer mismatches fail explicitly. The editor ignores the
system light appearance, as Photos editing and Final Cut Pro do; Increase Contrast
and Reduce Motion still follow the system. AVPlayerView remains the video trim
surface for native containers.
