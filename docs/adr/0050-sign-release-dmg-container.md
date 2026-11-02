# 50. Sign the release DMG container

Date: 2026-11-02
Status: Accepted

## Context

The owner requested a signed DMG. Packaging already signs the application,
extension and helper, but leaves the outer disk image unsigned.

## Decision

Sign the completed DMG with the same configured identity and verify its
signature before computing SHA-256. Reuse the existing signing arguments and
fail packaging if signing or verification fails. Local ad-hoc packaging keeps
its explicit opt-in. Retain the existing self-signed, unnotarized distribution.

## Consequences

The checksum covers the signed container. This does not establish Apple
notarization or remove the documented first-launch Open Anyway requirement.
