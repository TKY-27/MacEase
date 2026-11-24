# Security Policy

## Supported versions

The first stable release is in preparation. Until it is published, report
vulnerabilities against `main`. After release, only the latest stable version
will receive security fixes.

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/TKY-27/MacEase/security/advisories/new).
Do not open a public issue.

Include the MacEase version, macOS version, a description of the impact, and a
minimal file or steps that reproduce the problem. Remove personal data from
reproduction files and logs before sharing them.

## Scope

MacEase decodes untrusted files with Apple frameworks and bundled open-source
libraries. Reports about crafted files that crash MacEase, corrupt or delete
files outside the selection, or escape the Finder extension sandbox are in
scope. Vulnerabilities in a bundled library are in scope when MacEase ships an
affected version.

## Release signing

Release builds use the project's stable self-signed code-signing certificate.
They are not Apple Developer ID signed or notarized. Debug builds are ad-hoc
signed. Verify a download against the SHA-256 checksum published with its
GitHub Release before opening it, then follow the README's first-launch steps.

The host, Finder Sync extension and bundled Mach-O code enable Hardened
Runtime. The host remains unsandboxed so it can process Finder selections and
commit or undo changes beside the originals. The Finder extension is sandboxed.
Only the host has the Apple Events entitlement for Finder Automation.
In normal Debug and Release builds, library validation is disabled only for
the bundled Python, FFmpeg, ffprobe
and two sherpa audio executables, which load bundled libraries without an
Apple Team ID. No bundled executable has a JIT entitlement. The host and extension keep
library validation. These settings do not provide Apple notarization.
App-hosted tests use a separate `DebugTests` configuration whose host disables
library validation for unteamed XCTest/package bundles; this host is not shipped.
See [ADR 0069](docs/adr/0069-hardened-runtime.md) and the
[runtime evidence](docs/spikes.md#hardened-runtime-2026-11-24).
