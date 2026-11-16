# ADR 0062: Single Services item

Date: 2026-11-17
Status: Accepted

## Context

ADR 0037 added a Finder Services fallback because iCloud-managed Desktop and
Documents suppress Finder Sync menus. Every registered MacEase bundle declared
the same service, including Debug builds in DerivedData. Finder then listed
**Process with MacEase… (MacEase)** and **Process with MacEase… (MacEase Dev)**
directly in the context menu, which users found noisy.

## Decision

Only Release builds declare the service. `App/Info.plist` is preprocessed and
the `NSServices` entry is guarded by `MACEASE_SERVICES`, which only the Release
configuration defines. The item is titled **MacEase…** in every language.

## Consequences

Users with one installed copy see one short Services item. Debug builds can no
longer exercise the Services route; verifying it requires a Release build.
Stale Debug copies stay registered with Launch Services until they are removed
or unregistered with `lsregister -u`.
