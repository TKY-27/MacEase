# 2. Menu file read through a sandbox read-only exception

Date: 2026-10-20
Status: Accepted

## Context

The sandboxed extension needs data only the host has: hidden menu items,
localized labels in the app's chosen language, Apple Intelligence and Java
availability, preset names and the request token. App Groups need a Team ID,
which an ad-hoc or self-signed build does not have.

## Decision

The host writes `~/Library/Application Support/MacEase/menu.json`. The extension
reads it through the entitlement
`com.apple.security.temporary-exception.files.home-relative-path.read-only`
scoped to that folder. The file holds fully resolved, localized menu entries,
so the extension contains no business logic beyond building the menu.

## Consequences

- Verified on macOS 27.0.1 with an ad-hoc signed extension; re-verify on
  macOS 26 with the release checklist.
- Temporary exception entitlements are not allowed on the Mac App Store, which
  is out of scope.
- If the file is missing, the extension shows only "Open MacEase".
