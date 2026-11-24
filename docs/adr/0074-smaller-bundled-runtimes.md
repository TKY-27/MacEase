# ADR 0074: Smaller bundled runtimes

Date: 2026-11-24
Status: Accepted

## Context

Node occupies about 140 MiB and requires a JIT exception solely for yt-dlp's
bundled EJS challenge solver. The pinned yt-dlp supports QuickJS-NG. Its small
interpreter trades longer challenge execution for a substantially smaller app.

The pinned EJS provider supports Deno ≥2.3.0, Node ≥22.0.0,
QuickJS ≥2023-12-09, every QuickJS-NG release, and deprecated Bun 1.2.11–1.3.14.
QuickJS 2025-04-26 and QuickJS-NG 0.12.0 are performance recommendations,
not minimum compatibility versions. These limits agree with the pinned
`utils/_jsruntime.py` and the Bun/QuickJS providers, as well as the upstream
[EJS guide](https://github.com/yt-dlp/yt-dlp/wiki/EJS).

## Decision

Build MIT-licensed QuickJS-NG 0.18.0 from its hash-pinned source. Keep yt-dlp
2026.10.26 and EJS 0.8.0 unchanged. Select only the bundled `qjs`, with no runtime
fallback, remote solver components or JIT entitlement. Preserve the exact
source and license in the existing media-tools source distribution and notices.

Keep solver temporary scripts within each request's temporary/staging directory.
The upstream provider unlinks them normally; request cleanup removes leftovers
on cancellation. Record real-download evidence and solver timing in
`docs/media-tools.md`.

Remove Python GUI/bootstrap packages, certifi tests and bytecode caches. Keep
all remaining source and extension modules, and retain isolated `-I -B` launches.
Standard-library test support remains available for runtime verification.

Strip debug and local symbols from media/audio Mach-O files before signing.
Retain external symbols for dynamic loading; hash audio helpers after signing.
A section-level comparison and exported-symbol comparison cover all 69 affected
files. Models and their validation reports remain unchanged. The Release host
already uses arm64, dead-code stripping and installed-product stripping; applying
additional local-symbol stripping saved zero bytes.

## Consequences

Three public YouTube videos downloaded with both runtimes. Their observed
solver calls took 0.82–0.87 seconds with Node and 3.00–3.57 seconds with QuickJS-NG.
QuickJS exposes standard OS modules, unlike Node's restricted permission mode.
Only the pinned solver and the player code it processes are executed.
The host's existing file and staging contracts remain authoritative.

Models remain bundled and unchanged. Quantization needs independent quality and
compatibility validation; deferred downloads would change offline behavior.

The unchanged Spleeter models occupy 78.64 MB, GTCRN 0.54 MB, and the compiled
upscaler 53.01 MB. Pure weight-width estimates suggest FP16 could save about
39 MB for Spleeter and 24 MB for the upscaler; INT8 could save about 59 MB and
36 MB respectively. Graphs and compiled metadata reduce those savings.
Either needs model conversion, runtime compatibility and perceptual validation.
The previously examined Spleeter FP16 release fails ONNX validation.
Deferring all model downloads could remove about 132 MB from installation,
while introducing first-use network, storage and availability requirements.
None of these product or quality changes is adopted.

The ad-hoc Release measurement on macOS 27.2.1 was 440,285,471 → 265,012,982
file bytes for the app and 222,307,969 → 177,087,473 bytes for its ULMO DMG.
Allocated app bytes were 446,648,320 → 269,783,040. The mounted DMG payload
matches the archive by component; APFS clone sharing is outside this metric.
