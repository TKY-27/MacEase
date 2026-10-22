# 28. Release readiness checks

Date: 2026-10-23
Status: Accepted

## Context

Local packaging reused generated third-party notices, which can predate
new Swift package dependencies even when native libraries remain usable.
Hosted CI can be unavailable because of account or runner restrictions.

## Decision

- Regenerate third-party notices before every DMG archive. Existing pin and
  license checks must succeed before packaging continues.
- Review available CI results. If hosted CI is unavailable or explicitly waived
  by the maintainer, record successful local build, test, lint, and packaging
  checks for the release sources.
- Keep the manual release checks in SPEC section 17. CI success alone does
  not authorize publication. An unavailable required check blocks release.

## Consequences

- Account or runner failures do not replace source and artifact validation.
- Local packaging cannot silently reuse stale third-party notices.
- The stable self-signed, non-notarized distribution strategy is unchanged.
