# 17. Staging recovery and termination cleanup

Date: 2026-10-22
Status: Accepted

## Context

Staging deletion can fail because of filesystem permissions or transient errors.
Forgetting failed paths prevents later recovery. Normal quit also cancels jobs
without waiting for their staging cleanup, leaving recoverable files at exit.

## Decision

- Remove a valid staging entry only after deletion succeeds or confirms absence.
  Retain failed paths across registry writes, sweeps and launches. Keep live
  staging distinct from cleanup candidates, and serialize registry changes.
  Log removal failures with private path context. Refuse new staging before
  allocation if the existing registry cannot be loaded; retry after it recovers.
- Snapshot pending jobs before cancelling them. Await their completion without
  blocking the main thread, with one shared five-second cleanup deadline.
  Five seconds bounds the additional quit delay for unresponsive operations.
- Log deadline expiry and retain staging for recovery at a later launch.
  This timeout does not bypass accepted undo requests, the commit barrier or
  history persistence. A history flush failure still cancels termination.
- Reuse AppKit's existing deferred termination reply. No new dependency,
  termination alert, or settings option is required.

## Consequences

Cooperative jobs finish cleanup before normal quit. Unresponsive jobs can leave
registered staging behind for retry. Forced termination still cannot guarantee
cleanup. Persistent permission failures remain visible in logs and keep their
registry entries until removal succeeds.
