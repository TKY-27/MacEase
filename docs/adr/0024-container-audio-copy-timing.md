# 24. Container audio copy timing

Date: 2026-10-22
Status: Accepted

## Context

ADR 0023 retains native audio preroll and presentation edits for AVAssetWriter.
Applying that packet selection to Matroska copies writes AAC packets before
the trim origin. Matroska, WebM, AVI, and FLV cannot consume native edit lists
or CoreMedia trim attachments.

For the existing AAC fixture, a requested 0.7-second keyframe trim starts at
0.5 seconds. AVAssetReader returns a partially trimmed packet before the next
whole audio frame at 0.512 seconds. Assigning the partial packet's audible
start to its full payload would overlap that next frame.

## Decision

- Keep native priming and trim attachments for MP4, MOV, M4V, and native audio
  extraction.
- For containers without edit lists, translate native audio packets to their
  whole-packet presentation times. Subtract the leading trim from the output
  timestamp, then discard packets that begin before the trim origin.
- Preserve Opus CodecDelay, SeekPreRoll, and CodecPrivate when copying between
  Matroska and WebM. These are the codec's defined delay mechanism, as specified
  in the [Matroska Opus mapping](https://www.matroska.org/technical/codec_specs.html#a_opus).
- Keep the existing common timeline shift for FLV video decode timestamps.
  Audio must use the same origin to retain its offset from video.

## Consequences

Compressed copies into containers without edit lists begin on a whole audio
frame. The boundary can differ by up to one audio frame; native output retains
sample-accurate edits. Packet payloads are copied without re-encoding. The
existing MKV timestamp expectation remains unchanged.
