# ADR 0058: Activity dismissal and update attention

Date: 2026-11-14
Status: Accepted

## Context

Closing Activity hid finished rows but reopening it restored them. Update
notifications only appeared when the available version changed, so an ignored
release stopped prompting after its first check.

## Decision

Retain failed results until the user dismisses their row or closes Activity.
Dismissed completion data and matching delivered notifications are removed.
Notification Center dismissal clears the corresponding Activity result. Running
jobs, paused extraction recovery, durable batch history and Undo are separate
from these transient results.

Notify once per 24 hours for a confirmed available release, and immediately
when a newer release appears. A manual check within the interval does not
repeat the notice. Keep an update attention glyph and accessible label visible
until the app is updated or a check finds no newer release. Put the download
action at the top of the menu.

## Consequences

Comparison and retry details are unavailable after their Activity result is
dismissed. Undo remains available from durable history and recent batches.
