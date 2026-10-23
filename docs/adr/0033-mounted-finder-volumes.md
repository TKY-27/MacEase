# 33. Finder monitoring across mounted volumes

Date: 2026-10-23
Status: Accepted

## Context

A JSON file has MacEase actions on the startup volume but no MacEase menu
on a separately mounted APFS disk image. Reattaching without `nobrowse`
does not change the result. Registering `/` alone does not cover that mount.

## Decision

Register `/` and every mounted volume root with Finder Sync. Refresh the
registration on workspace mount, unmount and volume-rename notifications.
Serialize updates and keep enumeration outside menu construction and action
handlers. Include hidden volumes, which users can navigate to directly.

## Consequences

Finder monitoring matches the existing mounted-volume scope. File access,
conversion, commit and Undo retain their existing permission and safety checks.
Validate the signed extension on a separate APFS volume and a network mount,
including a volume attached after extension startup.
