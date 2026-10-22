# AGENTS.md

Instructions for AI coding agents working on MacEase.

## 1. Source of truth

- Read `docs/SPEC.md` before any work. It describes the finished v1.
- `docs/SPEC.md` wins over code, comments and other documents on conflicts.
- When a decision changes, update `docs/SPEC.md`, add an entry to its
  `## Changelog`, and add an ADR under `docs/adr/` (next number, same format).
- `docs/spikes.md` records verified platform behavior. Do not re-litigate it
  without new evidence; add new findings there.

## 2. Commands

Run from the repository root.

| Purpose | Command |
| --- | --- |
| Install tools, build native dependencies, generate the Xcode project | `make bootstrap` |
| Rebuild native dependencies only | `scripts/build-deps.sh` |
| Generate the Xcode project | `xcodegen generate` |
| Build the app (Debug) | `make build` |
| Unit tests (package) | `make test` (runs `swift test --package-path Packages/MacEaseKit`) |
| Full tests on a real Mac, including capability-gated tests | `make test-device` |
| Lint | `make lint` (runs `swift format lint --strict --recursive App FinderSync Packages`) |
| Format | `make format` (runs `swift format format --in-place --recursive App FinderSync Packages`) |
| Create the release signing identity (into `build/signing/`) | `scripts/create-signing-identity.sh [--set-secrets] [dir]` |
| Release DMG locally (identity from an unlocked keychain file) | `MACEASE_SIGNING_KEYCHAIN=<path> make dmg` |
| Ad-hoc signed DMG for local testing | `MACEASE_ALLOW_ADHOC=1 make dmg` |
| Benchmarks | `scripts/bench.sh` |
| Regenerate the app icon and template glyph assets | `swift scripts/make-app-icon.swift` |

Builds treat warnings as errors. Keep these commands working as the project
grows; if one changes, update this table and README.md in the same commit.

## 3. Code Quality Rules

AI slop is code that compiles and passes a glance review but degrades the codebase. It is forbidden everywhere, with no exceptions.

Comments
- Never write a comment of 8 or more words. This includes doc comments.
- Comment only why: intent, constraint, trade-off, surprising behavior.
- Never restate the code, echo a signature, or narrate steps.
- No placeholder, TODO, section-divider or commented-out code.
- Prefer a clearer name over any comment.

Structure
- No speculative abstraction: no single-implementation interfaces or protocols, no single-product factories, no layers without a second caller.
- No single-use helpers unless they clearly improve readability.
- No over-modularization: do not split simple logic across files.
- No god functions; keep functions short with one responsibility.
- Search the codebase before adding a helper; reuse, never duplicate.
- Use the standard library and platform APIs before writing your own.
- Follow the language's official style guide and the existing patterns in the repo.

Correctness and safety
- Never swallow errors or add silent fallbacks; handle specific, expected errors.
- No defensive bloat: do not re-validate already-typed inputs; validate at trust boundaries only.
- No unsafe casts, force unwraps or `any` to silence the compiler; fix the types.
- Verify every dependency exists and every API against official docs; keep dependencies minimal.
- No hardcoded magic values; use named constants or configuration.
- No secrets in code or logs.

Naming
- Specific domain names. Never `data`, `info`, `item`, `manager`, `helper`, `util`, `process`, `handle`, `temp` as a whole name.

Hygiene
- No dead code, unused imports, debug prints or leftover experiments.
- Formatter and linter must pass with zero warnings.

Tests
- Test behavior, not implementation; no mocking so heavy the test only checks the mock.
- Never edit, weaken, skip or delete a test to make it pass; fix the code.
- Never game checks in any way.

### Project-specific rules

- GPL-family sources: you may read GPL, LGPL and AGPL projects (FFmpeg, LAME,
  gifski, pngquant, libimagequant, Clop and others) to study architecture and
  algorithms. Never copy, translate, adapt or incorporate their code into
  MacEase; implement independently (ADR 0013).
- Flect (Apache-2.0) is the design reference for interaction and features.
  Reuse its code only with the Apache-2.0 notices that require; see ADR 0013.
- Never write to, move or delete a user's original file except through the
  commit sequence in SPEC.md section 3.5.
- Finder Sync action handlers run off the main thread. Do not isolate the
  extension's principal class to the main actor; handlers only read
  `sender.tag` and the selection, then open the request URL.
- Capability-gated tests skip only when the capability probe says it is
  missing. Skipping for any other reason counts as weakening a test.
- New native dependencies must be permissively licensed, pinned in
  `Vendor/deps.lock` and recorded in SPEC.md section 3.7.

## 4. Git

- Commit in logical units or at clean stopping points.
- Conventional Commits in English (`feat:`, `fix:`, `refactor:`, `test:`,
  `docs:`, `build:`, `ci:`, `chore:`), imperative mood, scope optional
  (`feat(video): add target-size planner`).
- Push to `main` directly.
- Never commit secrets, signing certificates, private keys, `Vendor/build/` or
  generated `.xcodeproj` files.
- Keep CI green. Do not push a commit you know breaks CI.

## 5. Workflow

1. Pick the next unit of work and check SPEC.md for its acceptance criteria.
2. Implement it with tests.
3. Build, run tests, lint.
4. Spawn a fresh review subagent with no prior context. Give it the diff,
   SPEC.md and the Code Quality Rules. Ask it to report spec deviations, bugs,
   data-loss risks and rule violations.
5. Fix every valid finding, re-run checks, then commit and push.

## 6. Documentation upkeep

- Keep README.md, README.ja.md and CHANGELOG.md in sync with what is actually
  implemented. Do not document features that do not work yet.
- README.ja.md mirrors README.md in Japanese.
- Record user-visible changes under `## [Unreleased]` in CHANGELOG.md.

## 7. Language

All code, comments, identifiers, documentation, commit messages and test names
are in English. The only exceptions are README.ja.md and the Japanese entries
in String Catalogs and preset names.
