# 4. MIT license and dependency policy

Date: 2026-10-20
Status: Accepted

## Context

MacEase is MIT-licensed. Popular media tools on macOS depend on GPL or AGPL
components (FFmpeg builds, gifski, pngquant, LAME is LGPL), which would force a
copyleft license or complicate distribution.

## Decision

- Use Apple frameworks first.
- Bundle only permissively licensed native libraries (BSD, MIT, Apache-2.0,
  0BSD), pinned by version and SHA-256, built from source.
- Write in-house Swift implementations where no permissive library exists: MP3
  encoder, GIF encoder, PNG quantizer and optimizer, Matroska/WebM, AVI and FLV
  containers, ICO and ICNS writers, SVG tracer.
- Follow a clean-room rule: never open or translate source code from GPL, LGPL
  or AGPL projects; implement from specifications and papers.
- Generate `THIRD_PARTY_NOTICES.txt` from the pinned sources, including patent
  license files (AOM, libvpx, libjxl).

## Consequences

- The project stays MIT and redistributable without copyleft obligations.
- The in-house components are substantial and each needs objective acceptance
  tests (SPEC.md section 3.8).
