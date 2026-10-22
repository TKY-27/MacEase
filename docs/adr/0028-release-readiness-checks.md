# 28. Release readiness checks

Date: 2026-10-23
Status: Accepted

## Context

The tag workflow could publish without checking CI for the tagged commit.
Local packaging also reused generated third-party notices, which can predate
new Swift package dependencies even when native libraries remain usable.

## Decision

- Require the latest push CI run on `main` for the tagged commit to succeed
  before the release workflow imports signing material or builds the DMG.
- Regenerate third-party notices before every DMG archive. Existing pin and
  license checks must succeed before packaging continues.
- Keep the manual release checks in SPEC section 17. CI success alone does
  not authorize publication. An unavailable required check blocks release.

## Consequences

- Account or runner failures block releases without being treated as code failures.
- Local packaging cannot silently reuse stale third-party notices.
- The stable self-signed, non-notarized distribution strategy is unchanged.
