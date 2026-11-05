# 55. Fades, waveforms, shuttle playback and download conveniences

Date: 2026-11-05
Status: Accepted

## Context

After the editor redesign (ADR 0054) the owner asked for four proposed additions:
a waveform in the video timeline, fade in/out for audio trimming and video
segments, loop playback with J/K/L shuttle keys, and yt-dlp link dropping,
clipboard pasting and thumbnails.

## Decision

Model fades as `FadeRamp`: linear ramps in output seconds that keep their
requested lengths and shrink proportionally only when together they exceed the
span. `VideoSegment` gains `fadeIn`/`fadeOut` (decoded as zero when
absent) and `AudioOperation.trim` gains defaulted fade parameters. Export applies
the ramp to PCM and scales colour toward black in `FrameProcessor`; preview uses
`AVAudioMix` ramps and the same colour scaling in the video composition. Audio
trim refuses fades longer than the kept range instead of clamping, because the
user sets both together; video shrinks overlapping fades because trims and speed
changes alter segment length later. Splitting clears the fades at the new cut.

Video waveforms decode each source once with the existing PCM path into 4,096
peaks and slice them per segment. Shuttle playback uses `AVPlayer` rates and
falls back to stepping when an item cannot play in reverse.

Clipboard suggestions use pasteboard pattern detection, which reports only that
a probable URL exists, so no paste-permission prompt appears and nothing is read
until the user clicks. Thumbnails are part of an explicit analysis; they are
fetched over HTTPS only, without cookies or credentials, with size, count and
concurrency limits.

## Consequences

Fades re-encode the trimmed audio and segmented video, as other edits already
do. Waveform decoding costs one background pass per source. Thumbnail requests
reach the media site's image hosts; this remains an explicitly requested
network action under section 1, not telemetry.
