# 1. Finder Sync extension with a URL scheme transport

Date: 2026-10-20
Status: Accepted

## Context

MacEase must complete every operation from the Finder context menu, with nested
submenus for operations and presets. macOS offers Services and Quick Actions
(flat lists under Quick Actions) and Finder Sync extensions (custom menus with
submenus at the top level of the context menu). Finder Sync extensions must be
sandboxed, so heavy processing and writing next to user files cannot happen in
the extension.

## Decision

- Use a Finder Sync extension for the menu and an unsandboxed menu bar host app
  for all processing.
- The extension sends requests to the host through a custom URL scheme
  (`macease://run?...`) opened with `NSWorkspace`. Each request carries the
  catalog version, the menu entry index (stored in `NSMenuItem.tag`), a secret
  token and the selected paths.
- The host rejects requests with a wrong token or a stale catalog version.

## Consequences

- The menu appears at the top level with up to four levels (verified).
- Opening files with the host through `NSWorkspace.open(_:withApplicationAt:)`
  did not deliver them, so it is not used.
- The URL scheme is reachable by any process and web page, which the token
  mitigates. Destructive deletions always require a confirmation panel.
- Large selections are carried in the URL; 5,000 paths were verified.
