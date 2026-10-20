# 3. Self-signed distribution without notarization

Date: 2026-10-20
Status: Accepted

## Context

MacEase is a personal open-source project distributed without an Apple Developer
Program membership, so it cannot be notarized. Ad-hoc signatures change with
every build, and macOS ties privacy grants (TCC) for ad-hoc code to the code
hash, so every update would ask again for access to Desktop, Documents,
Downloads and other locations. Homebrew's official cask repository stopped
accepting casks that fail Gatekeeper in September 2026.

## Decision

- Distribute a DMG through GitHub Releases only.
- Sign releases with a self-signed code-signing certificate kept in repository
  secrets. The stable certificate gives the app a stable designated requirement,
  so TCC grants and the extension's enabled state survive updates.
- Debug builds are ad-hoc signed with a separate bundle ID.
- Document the first-launch steps (Open Anyway or `xattr`) in the README.

## Consequences

- Users still see the Gatekeeper warning on first launch.
- Losing the certificate's private key resets user grants once; the key must be
  backed up outside GitHub.
- Survival of grants across updates is part of the manual release checklist.
