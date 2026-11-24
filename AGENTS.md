# AGENTS.md

- `docs/SPEC.md` describes the finished product and wins over code, comments and other documents. When a decision changes, update SPEC, add a dated entry to its `## Changelog` and add the next-numbered ADR under `docs/adr/` in the existing format. `docs/spikes.md` records measured platform behaviour: add findings, never re-argue them without new evidence.
- Commands are the Makefile targets (`make bootstrap`, `build`, `test`, `test-app`, `test-device`, `lint`, `format`); `make test` runs the package tests one at a time with the pinned media runtime, and `make test-device` adds the capability-gated and app-hosted tests on a real Mac. Scripts and release commands are in CONTRIBUTING.md. `make lint` must pass with zero warnings; builds treat warnings as errors.
- Comments state only why (intent, constraint, trade-off, surprise), in fewer than eight words, doc comments included; never restate code, leave TODOs or keep commented-out code.
- No speculative abstraction: no single-implementation protocols, single-product factories, layers without a second caller or single-use helpers. Reuse what exists before adding a helper.
- Never swallow errors or add silent fallbacks; never use force unwraps, unsafe casts or `any` to silence the compiler; no dead code, debug prints or magic values.
- Never name an identifier just `data`, `info`, `item`, `manager`, `helper`, `util`, `process`, `handle` or `temp`.
- Never edit, weaken, skip or delete a test to make it pass. Capability-gated tests skip only when their capability probe reports the capability missing.
- A user's original is written, moved or deleted only through the commit sequence in SPEC section 3.5.
- GPL, LGPL and AGPL code (FFmpeg, LAME, gifski, pngquant, libimagequant, Clop and others) is reference only: never copy, translate or adapt it (ADR 0013). Only the isolated, never-linked executables allowed by SPEC sections 22–25 and ADRs 0052, 0053, 0057 and 0082 may ship. Flect (Apache-2.0) code may be reused only with its notices. New native dependencies must be permissively licensed, pinned in `Vendor/deps.lock` and listed in SPEC section 3.7.
- Finder Sync action handlers run off the main thread: never isolate the extension's principal class to the main actor; handlers only read `sender.tag` and the selection, then open the request URL.
- Keep README.md, its Japanese mirror README.ja.md and CHANGELOG.md `## [Unreleased]` in step with what actually works; never document unfinished features.
- Commit to `main` directly in logical units with Conventional Commits in imperative English (`feat(video): add target-size planner`); keep CI green. Never commit secrets, signing material, `Vendor/build/` or generated `.xcodeproj` files.
- Everything is in English except README.ja.md and the Japanese entries of String Catalogs and preset names.
