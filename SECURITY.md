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
