# 9. In-house MP3 encoder

Date: 2026-10-20
Status: Accepted

## Context

SPEC.md section 3.8 requires an MPEG-1 Layer III encoder written from
ISO/IEC 11172-3, because LAME and shine are LGPL. The encoder needs the
standard's Huffman code tables and the 512-tap analysis window, which are
normative data that cannot be derived.

## Decision

- The Huffman tables and the synthesis window come from PDMP3, a public
  domain (Unlicense) MP3 decoder that carries them from ISO/IEC 11172-3
  annex B. A local generator walked its decoding trees into the encoder's
  code and length tables; the analysis window is the synthesis window divided
  by 32, as the standard defines. No encoder code was consulted.
- The psychoacoustic model works on MDCT energies per scalefactor band: tonality
  from spectral flatness, Schroeder spreading over Bark, tone and noise masking
  offsets, Terhardt's threshold in quiet calibrated against a full-scale sine,
  and growth limiting against pre-echo. Window switching uses a high-passed
  energy transient detector with one granule of lookahead.
- CBR uses the ISO inner and outer loops with a bit reservoir and perceptual
  entropy budgets. VBR finds the coarsest quantization that keeps every band
  under its threshold, then picks the smallest bitrate whose slot and reservoir
  hold it. VBR files start with a Xing frame.
- Quality 0 to 9 maps to masking thresholds from 22 dB tighter to about 1 dB
  looser than the model's.

## Consequences

- The encoder decodes cleanly in AudioToolbox and meets the 192 kbps quality
  and bandwidth targets on the music fixture.
- AudioToolbox output lags the input by 528 samples, the encoder's analysis
  delay after the decoder trims its own; no gapless metadata is written.
