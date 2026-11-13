# HatchZip core update for MacEase v3

## Pin and scope

- Upstream release: [`v0.1.10`](https://github.com/xevrion/hatchzip/releases/tag/v0.1.10), published 2026-11-10.
- The GitHub tag resolves to commit `e56b4ceca0d28e967ce04834895e693c84a2a7a0`.
- The [source archive](https://codeload.github.com/xevrion/hatchzip/tar.gz/e56b4ceca0d28e967ce04834895e693c84a2a7a0) has SHA-256 `4db5d76a8ea69a111c9f9630ae80b28e6af7c9f2f18fa5db7dd727f3ccf7bb02`.
- The Finder menu remains limited to ZIP, 7z, TAR and tar.gz/tgz, including supported numbered volumes. The helper still rejects tar.xz and keeps UnRAR disabled through `default-features = false`.

## Security and compatibility

HatchZip 0.1.10 compares archive paths with filesystem folding and refuses Unicode case or normalization collisions before removing archive bytes. It also protects resume from differently spelled names and refuses unsupported 7z methods during preflight. The prior 0.1.9 fixes for dot-only output names, hard-linked volumes and extracted-output verification remain.

MacEase keeps its exclusive output directory and stricter absolute-path rejection for ZIP and TAR entries. The adapted patch applies quarantine and syncs output before each persistent checkpoint, then records the `finishing` manifest before upstream removes the archive. The helper supplies HatchZip's new folder metadata side-file path inside its private session. Upstream now restores folder permissions and modified times at the end.

If the saved folder list is lost after every member is safe, HatchZip completes with a warning that those attributes kept their default values. MacEase forwards this to the Activity warning pipeline. Folder attribute application errors remain errors. Each build extracts the verified archive into a separate directory, applies the patch there, and replaces only the revision-named source after preparation succeeds. Cargo recompiles the core from that tree. The existing shared `Vendor/src/hatchzip` tree is untouched.

## Dependencies and licenses

The isolated helper adds `unicode-normalization` 0.1.26, `tinyvec` 1.13.3 and `lzma-rust2` 0.24.0. `lzma-rust2` 0.23.0 remains through sevenz-rust2. The resolved aarch64 macOS dependency set contains no GPL, LGPL, AGPL or UnRAR package. The generated notices include the new crates' license texts. The core remains MIT OR Apache-2.0, and both upstream license files are copied by the build script.

## Verification

- `scripts/build-hatchzip.sh` built the release helper from the pinned archive and generated notices.
- A deliberately added file in the revision-named source disappeared on rebuild; the rebuilt tree matched a fresh extracted-and-patched copy.
- `scripts/test-hatchzip.py` passed against the release helper for ZIP, TAR, tar.gz, 7z, numbered volumes, strict paths, passwords, corruption, expansion, hard links, quarantine, pause/resume and recovery identity.
- A Debug helper run with `MACEASE_HATCH_VERIFY_TEST=1 MACEASE_HATCH_CRASH_TEST=1` passed the output-verification and crash-recovery cases.
- A ZIP with `straße.txt` and `STRASSE.txt` was refused before mutation; the archive bytes were unchanged.
- An actual Debug crash at `before-folders`, removal of the saved folder list and resume produced the warning while preserving the extracted payload.
- Added 0.1.9 cases still confirm dot-only names, hard-linked split volumes and the tar.xz refusal.
- The constrained APFS sparse-image test was not run. Full Swift and app suites belong to parent integration.
