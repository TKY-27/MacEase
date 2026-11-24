# ADR 0069: Hardened Runtime with isolated runtime exceptions

Date: 2026-11-24
Status: Accepted

## Context

MacEase disabled Hardened Runtime. Its self-signed release and ad-hoc Debug
identities have no Apple Team ID. Bundled interpreters and audio/media tools
load non-system code in separate processes. See the measured failures in
`docs/spikes.md`, Hardened Runtime.
Exception measurements use ad-hoc signatures. Equal behavior with the existing
self-signed release identity is inferred from its absent Apple Team ID; that
identity was not used for these measurements.

## Decision

Enable Hardened Runtime on the host, Finder extension and all bundled Mach-O
code in both configurations. Share the nested-code signing policy between
helper builds, `make project` and DMG packaging, and verify runtime flags.
Reject unexpected entitlement sets as well as missing runtime flags in Debug
builds and DMG packaging, using the same verification script.
Pass `--options runtime` explicitly: Xcode otherwise disables it for ad-hoc
signing. Disable Xcode's debug dylib mode instead of weakening host or
extension library validation for its unteamed debug/preview libraries.
Keep the existing signing identity and unnotarized distribution.

For normal Debug and Release builds, grant Apple Events access only to the host
for Finder Automation. Grant
disable-library-validation only to Python, FFmpeg, ffprobe and the two sherpa
audio executables: their bundled libraries fail Team ID validation. Grant
allow-jit only to Node: V8 fails to reserve its CodeRange without it.
Preserve dylib ABI install names so hardened dyld accepts versioned symlinks.
Do not grant unsigned-executable-memory or DYLD-environment exceptions.

Run app-hosted tests in an isolated `DebugTests` configuration, with a distinct
bundle ID and support folder. Its hardened host disables library validation
only to load unteamed XCTest and package bundles. Keep all existing tests and
the ordinary Debug/Release host entitlements unchanged by this exception.

Keep the host outside App Sandbox. Authentication of Finder path strings does
not grant sandbox file access. Sandboxing requires a separately designed
file-authorization, commit/Undo, helper and Finder Preview workflow.

## Consequences

The host and extension retain library validation; exceptions remain within
the child processes that require them. Hardened Runtime does not constrain
ordinary file access or provide notarization. The extension stays sandboxed.
