# 6. Build system and CI

Date: 2026-10-20
Status: Accepted

## Context

The app targets macOS 26 but uses macOS 27 Foundation Models image input when
available. GitHub's `macos-26` runner image ships only Xcode 26; Xcode 27 is on
the separate `xcode-27` image, generally available since 2026-10-15.

## Decision

- XcodeGen generates the Xcode project from `project.yml`; core logic lives in
  the local Swift package `MacEaseKit`.
- macOS 27-only APIs are isolated per feature behind `#if compiler(>=6.4)` and
  `#available(macOS 27, *)` so the project builds with Xcode 26 and 27.
- CI runs lint on `macos-26`, and build plus tests on both `macos-26` (Xcode 26)
  and `xcode-27` (Xcode 27). Releases build on `xcode-27`.
- Native dependencies are built from pinned sources by a script and cached by
  the hash of the lock file and the script.

## Consequences

- If the `xcode-27` image changes label or status, update the workflows and this
  ADR.
- Tests that need hardware encoders, Apple Intelligence or downloadable OS
  assets skip on CI and run with `make test-device`.
