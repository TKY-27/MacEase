# Security Policy

## Supported versions

Only the latest release receives security fixes.

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/TKY-27/MacEase/security/advisories/new).
Do not open a public issue.

Include the MacEase version, macOS version, a description of the impact, and a
minimal file or steps that reproduce the problem. You can expect an initial
response within 7 days.

## Scope

MacEase decodes untrusted files with Apple frameworks and bundled open-source
libraries. Reports about crafted files that crash MacEase, corrupt or delete
files outside the selection, or escape the Finder extension sandbox are in
scope. Vulnerabilities in a bundled library are in scope when MacEase ships an
affected version.

## Unsigned builds

Releases are ad-hoc signed and not notarized. Verify a download against the
SHA-256 checksum published with each release before opening it.
