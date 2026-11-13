# v3 dependency update review — 2026-11-14

## Current stable releases and decisions

| Dependency | Current stable release | MacEase pin | Decision |
| --- | --- | --- | --- |
| [HatchZip](https://github.com/xevrion/hatchzip/releases/tag/v0.1.10) | 0.1.10, published 2026-11-10 | 0.1.10 | Update the isolated `hatchzip-core` helper from 0.1.9. |
| [yt-dlp](https://pypi.org/project/yt-dlp/) | 2026.10.26 | 2026.10.26 | Keep the existing stable source pin. |
| [gallery-dl](https://pypi.org/project/gallery-dl/) | 1.32.19 | 1.32.19 | Keep the existing stable source pin. |
| [yt-dlp-ejs](https://pypi.org/project/yt-dlp-ejs/) | 0.8.0 | 0.8.0 | Keep the existing source and wheel pins. |

RustXNG has no reference in the tracked MacEase repository. The [upstream project](https://github.com/sahenjp/RustXNG) is an AGPL-3.0 metasearch service, not an archive or media codec dependency. No RustXNG dependency was added.

## HatchZip source, compatibility and licenses

The 0.1.10 GitHub tag resolves to commit `e56b4ceca0d28e967ce04834895e693c84a2a7a0`. The [source archive](https://codeload.github.com/xevrion/hatchzip/tar.gz/e56b4ceca0d28e967ce04834895e693c84a2a7a0) has SHA-256 `4db5d76a8ea69a111c9f9630ae80b28e6af7c9f2f18fa5db7dd727f3ccf7bb02`. `Vendor/deps.lock` records the exact URL, checksum and MIT OR Apache-2.0 licenses. The existing MacEase checkpoint, quarantine and strict-path patch was adapted to this source. RAR remains disabled, and the Finder format scope was not expanded.

The helper now supplies HatchZip's folder metadata side-file path in its private session and accepts the upstream completion warning result. A warning is included in the existing `finished` response's optional `message` field. Swift maps it to the existing Activity warning pipeline, keeping the extraction successful while telling the user that some folder permissions and modified times were not restored.

The resolved arm64 macOS Cargo graph adds `unicode-normalization` 0.1.26, `tinyvec` 1.13.3 and `lzma-rust2` 0.24.0. The existing `lzma-rust2` 0.23.0 remains through sevenz-rust2. `cargo metadata` reports permissive licenses for the resolved helper graph; no GPL, LGPL, AGPL or UnRAR package is resolved. Notice generation includes license text for the new crates.

## Verification performed

- `scripts/build-hatchzip.sh`: release build and third-party notice generation passed from the pinned archive and adapted patch. The script re-extracts and patches in a separate directory on each build, replaces only the revision-named source tree after preparation, and recompiles the core.
- `python3 scripts/test-hatchzip.py Vendor/build/macease-hatchzip`: passed ZIP, TAR, tar.gz, 7z, split volumes, source protection, quarantine, strict paths and pause/resume checks.
- A direct ZIP fixture with `straße.txt` and `STRASSE.txt` was rejected before source mutation; the archive bytes were unchanged.
- A Debug helper was stopped at `before-folders`; deleting its saved folder list and resuming produced a successful extraction with the upstream warning. The extracted payload remained intact.
- A Debug build passed `MACEASE_HATCH_VERIFY_TEST=1 MACEASE_HATCH_CRASH_TEST=1 python3 scripts/test-hatchzip.py Vendor/build/hatchzip-target/debug/macease-hatchzip`.
- A warning event reached the job's `ItemWarning` output in the focused `HatchExtractionTests` suite (6/6 passed).
- `cargo fmt --manifest-path Native/HatchZip/Cargo.toml --check` and `git diff --check` on the owned files passed.
- The existing private media runtime reported yt-dlp `2026.10.26` and gallery-dl `1.32.19`. It was not rebuilt because their pins did not change.

The parent package run in `build/v3.0.0/resume-package.log` had one Engine test failure among 992 tests: `ArchiveBrowserSessionTests.closingDuringActivePreviewStopsWritingAndCleansStaging` did not observe partial ZIP preview output. ZIP Browse uses Swift `ArchiveBrowserZIP`, not this HatchZip helper. The same test passed in 0.524 seconds when run alone with `swift test --skip-build --filter 'ArchiveBrowserSessionTests.closingDuringActivePreviewStopsWritingAndCleansStaging'`. This does not establish a cause for the full-run failure. No test or production code was weakened for it.

The full package and app suites are tracked by parent integration in `docs/v3.0.0-validation.md`. SPEC and the release documentation use the final 0.1.10 pin.
