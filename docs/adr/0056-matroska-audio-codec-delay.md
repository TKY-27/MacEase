# 56. Matroska audio codec delay

Date: 2026-11-05
Status: Accepted

## Context

ADR 0024 placed copied non-Opus audio in Matroska and WebM on whole packets of
the edited presentation timeline. For AAC from MP4 this drops the priming
packets the decoder needs, drops a partially trimmed first packet, and leaves
the end padding audible. Converting the 2-second fixtures to MKV decoded to
96,256 instead of 96,000 AAC-LC frames, and to 88,064 instead of 88,200 HE-AAC
frames, with HE-AAC missing its first 1,920 audible frames (43.5 ms early).

FFmpeg's remux keeps every packet, writes the priming as `CodecDelay` and the
end trim as `DiscardPadding`, and decodes to the MP4 length. HE-AAC tracks also
carry the AudioSpecificConfig core rate in `SamplingFrequency` and the SBR rate
in `OutputSamplingFrequency`, matching the element definitions. MacEase wrote
the SBR rate as `SamplingFrequency`, which its own decoder could not open.

## Decision

- Keep the priming packets of non-Opus native audio copied into Matroska and
  WebM. The leading trim run becomes `CodecDelay`, block times move by that delay, and
  trailing trim becomes `DiscardPadding`. Later leading trims keep ADR 0024's
  whole packets.
- Write the AudioSpecificConfig core rate as AAC `SamplingFrequency`, and the
  signalled or decoded SBR rate as `OutputSamplingFrequency` when it differs.
- Decode Matroska and WebM audio by dropping `CodecDelay` for every codec.
- Copies of Matroska `CodecDelay` audio into AVI, FLV or extracted audio drop
  whole priming packets, start the next packet at the audible start, and leave
  trailing padding unsignalled, within ADR 0024's one-frame tolerance.
- Native MP4, MOV and M4V copies keep every packet, as before. AVAssetWriter
  ignored synthesized trim attachments in every tested form, and untrimmed audio
  before the session start stalled `finishWriting`.

## Consequences

FFmpeg decodes MKV conversions of the AAC-LC, HE-AAC and HE-AAC v2 fixtures to
the same samples as their MP4 sources, also after a further Matroska copy.
MacEase decodes the AAC-LC MKV like its source. Matroska AAC with `CodecDelay`
and end padding now copies to FLV instead of refusing its padding.

Native copies of Matroska `CodecDelay` audio still play the priming, so audio
starts late by the delay: 21 ms for the AAC-LC fixture and 96 ms for HE-AAC.
Extract Original Audio refuses such tracks, as it already did for FFmpeg files.
The Matroska reader still uses `SamplingFrequency`, so HE-AAC from Matroska
decodes at its core rate and HE-AAC v2 fails to decode. Decoding the SBR layer
needs the richest decodable AudioToolbox format and an end-of-stream flush.
