# ADR 0081: Hideable menu-bar item and automatic update switch

Date: 2026-11-24
Status: Accepted

## Context

The status item was the only way to reach Settings and recent operations, and
MacEase contacted GitHub at launch and once a day without a way to stop it.
Some users keep their menu bar minimal, and some prefer to check for updates
themselves.

## Decision

Add three switches to Settings > General, all on for new and existing
installations: Check for updates automatically, Show in menu bar and Show
recent operations. Hide the status item when Show in menu bar is off; opening
MacEase again, from Finder, the Applications folder or `macease://open`, always
reaches Settings, or Welcome before setup. Show recent operations hides only the
Recent block and is disabled while the item is hidden. With automatic checks off, make
no request at launch or on the timer; the menu-bar Check for Updates always
requests. Reset All Settings turns all three on.

## Consequences

The app stays reachable without the status item. While it is hidden there is no
attention badge, so failures and a disabled Finder extension are visible only
through notifications, Activity and Settings; an available update still shows
in Finder's menu and through notifications. With automatic checks off, users
learn about updates only when they check.
