# ADR 0065: Update window and Finder item

Date: 2026-11-17
Status: Accepted

## Context

Menu bar and notification download links do not explain manual installation
or restoring Finder extension and privacy access. Finder users need a visible
update entry without starting a file operation. Finder Sync ignores attributed
titles but preserves menu images.

## Decision

Keep schema 3 and add optional localized updateTitle to menu.json and its
catalog hash. Preserve it when expanding recipe entries. Observe the host's
availableVersion and rewrite the menu file when it changes or clears.

Place the update entry first inside MacEase, followed by a separator, only
when the host is available. Cache one system-blue, non-template SF Symbol in
the extension. Use macease://update?t=<token>, authenticated against the current
menu token with RequestToken.matches. Reject missing, duplicate or mismatched
tokens and unavailable hosts. This route has no job, selection or history.

Use SingleWindowPresenter for one compact native Update window shared by
Finder, the menu bar and update notifications. Show the available and running
versions, the localized official download link, Later, five manual installation
steps and Finder Sync's extension settings action. Repeated opens focus the
existing window; clearing availability closes it. Downloads remain manual.

## Consequences

Users can discover updates from Finder and read installation guidance before
visiting the official site. Old schema-3 menu files remain readable and omit
the update entry. Catalog and app-hosted regressions cover optional decoding,
hash changes, authenticated routing and single-window reuse. Build, test
execution, native layout and Finder icon rendering need host validation.
